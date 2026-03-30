#!/bin/bash

# This script will enable the backend for an customer instance.
# All needed credentials are loaded/stored from/to the Bitwarden Secrets Manager

# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./enable-backend.sh <instance> (optional) <password>
# example: ./enable-backend.sh qm
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#

##############################
# setup
##############################

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

# check if BWS_ACCESS_TOKEN is set
if [[ -z "${BWS_ACCESS_TOKEN}" ]]; then
  echo "BWS_ACCESS_TOKEN is not set. Abort."
  exit 1
fi

# set server-base to EU instance
bws config server-base https://vault.bitwarden.eu

##############################
# ask for input data
##############################

if [ -n "$1" ]; then
  instance="$1"
else
  echo "What is the name of the instance?"
  read -r instance
fi

##############################
# variables
##############################

path="$baseDirectory/$PREFIX$instance"

# load secrets from Bitwarden Secret Manager
RENDER_API_CLIENT_ID_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b53d7a1d-220e-4e07-b1f9-b22700711f79" | jq -r .value)
RENDER_API_CLIENT_SECRET_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "83a8e38b-fc22-461f-91a0-b22700712b62" | jq -r .value)
SENTRY_AUTH_TOKEN=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b9a3e1eb-3925-4ed6-93f4-b2270073c82c" | jq -r .value)
SENTRY_DSN_BACKEND=$(bws secret -t "$BWS_ACCESS_TOKEN" get "a858a580-9643-4330-8667-b2270073d7a6" | jq -r .value)
KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789

isBackendEnabled=0
isBackendConfigCreated=0
isReplicationBackendEnabled=0

# setting backend version. Use latest available version by default.
backendVersion=

##############################
# functions
##############################

backendEnabledCheck() {
  composeProfiles=$(getVar "$path/.env" COMPOSE_PROFILES)

  if [ "$composeProfiles" = "full-stack" ]; then
    isBackendEnabled=1
  else
    isBackendEnabled=0
  fi
}

isBackendConfigCreated() {
  if [ ! -f "$path/config/aam-backend-service/application.env" ]; then
    isBackendConfigCreated=0
  else
    isBackendConfigCreated=1
  fi
}

setLatestBackendVersion() {
  backendVersion=$(curl -s https://api.github.com/repos/Aam-Digital/aam-services/releases | jq -r 'map(select(.name | test("^aam-backend-service/"))) | .[0].name | split("/") | .[1]')
}

replicationBackendEnabledCheck() {
  composeProfiles=$(getVar "$path/.env" COMPOSE_PROFILES)

  if [ "$composeProfiles" == "database-only" ]; then
    isReplicationBackendEnabled=0
  else
    isReplicationBackendEnabled=1
  fi
}

setEnv() {
    local key="$1"
    local value="$2"
    local path="$3"
    # escape sed special characters in value (\, &, |)
    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')

    sed -i "s|^$key=.*|$key=$escaped|g" "$path" # linux
    # gsed -i "s|^$key=.*|$key=$escaped|g" "$path" # macos
}

# Funktion zum Abrufen der Umgebungsvariablen
getVar() {
    local file="$1"
    local var="$2"
    local value

    # grep sucht die Zeile mit der Variable, cut extrahiert den Wert
    value=$(grep "^$var=" "$file" | cut -d '=' -f2-)

    # Falls die Variable nicht existiert oder leer ist, eine Meldung ausgeben
    if [ -z "$value" ]; then
      value="n/a"
    fi

    echo "$value"
}

generate_password() {
  password=""
  for _ in {1..24} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

getKeycloakToken() {
  token=$(curl -s -L "https://$KEYCLOAK_HOST/realms/master/protocol/openid-connect/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode username="$KEYCLOAK_USER" --data-urlencode password="$KEYCLOAK_PASSWORD" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli)
  token=${token#*\"access_token\":\"}
  token=${token%%\"*}
}

createKeycloakBackendClient() {
  local realm="$1"
  clientSecret=""

  getKeycloakToken

  # check if aam-backend client already exists (idempotent)
  local existing
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=aam-backend" \
    -H "Authorization: Bearer $token")
  clientUuid=$(echo "$existing" | jq -r '.[0].id // empty')

  if [ -z "$clientUuid" ]; then
    # create the aam-backend client (confidential, service account enabled)
    clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/clients" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d '{
        "clientId": "aam-backend",
        "enabled": true,
        "clientAuthenticatorType": "client-secret",
        "serviceAccountsEnabled": true,
        "publicClient": false,
        "standardFlowEnabled": false,
        "directAccessGrantsEnabled": false,
        "protocol": "openid-connect"
      }')

    # extract client UUID from Location header
    location=$(echo "$clientResponse" | grep -i "^location:")
    clientUuid=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

    if [ -z "$clientUuid" ]; then
      echo "ERROR: Failed to create aam-backend client in Keycloak realm '$realm'."
      return 1
    fi

    echo "Created aam-backend client: $clientUuid"
  else
    echo "aam-backend client already exists: $clientUuid"
  fi

  # get client secret
  clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/client-secret" \
    -H "Authorization: Bearer $token" | jq -r '.value // empty')

  if [ -z "$clientSecret" ]; then
    echo "ERROR: Failed to retrieve client secret for aam-backend client in realm '$realm'."
    return 1
  fi

  # get the service account user
  serviceAccountUserId=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/service-account-user" \
    -H "Authorization: Bearer $token" | jq -r '.id // empty')

  if [ -z "$serviceAccountUserId" ]; then
    echo "ERROR: Failed to retrieve service account user for aam-backend client in realm '$realm'."
    return 1
  fi

  # get the realm-management client UUID
  realmMgmtClientUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=realm-management" \
    -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

  if [ -z "$realmMgmtClientUuid" ]; then
    echo "ERROR: Failed to retrieve realm-management client in realm '$realm'."
    return 1
  fi

  # get the manage-realm role from realm-management client
  manageRealmRole=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$realmMgmtClientUuid/roles/manage-realm" \
    -H "Authorization: Bearer $token")

  # assign manage-realm role to the service account
  curl -s -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/users/$serviceAccountUserId/role-mappings/clients/$realmMgmtClientUuid" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "[$manageRealmRole]"

  echo "Assigned manage-realm role to aam-backend service account."
}

##############################
# script
##############################

setLatestBackendVersion
echo "Latest backendVersion available: $backendVersion"

# check if backend is already enabled for this instance
backendEnabledCheck
isBackendConfigCreated

if [ "$isBackendEnabled" == 1 ]; then
  echo "Backend already enabled for '$instance'. Abort."
  exit 1
else
  echo ""
fi

if [ "$isBackendConfigCreated" == 1 ]; then
  echo "Backend config already created for '$instance'. Abort."
  exit 1
else
  echo ""
fi

replicationBackendEnabledCheck

if [ "$isReplicationBackendEnabled" == 0 ]; then
  # all functionality should be the same with a direct CouchDB without replication-backend. However, some URLs will need to be adapted for this scenario
  echo "Replication Backend is required for backend. Please enable first. Abort."
  exit 1
else
  echo ""
fi

(cd "$path" && docker compose down)

# set aam-backend-service-version to supported version
setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

# create backend config directory
mkdir -p "$path/config/aam-backend-service"

# copy latest template config (from aam-services repository)
curl -L -o "$path/config/aam-backend-service/application.env" "https://raw.githubusercontent.com/Aam-Digital/aam-services/refs/tags/aam-backend-service/$backendVersion/templates/aam-backend-service/application.template.env"

generate_password

setEnv CRYPTO_CONFIGURATION_SECRET "$password" "$path/config/aam-backend-service/application.env"
setEnv SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI "https://keycloak.aam-digital.com/realms/$instance" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_USERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_PASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH "http://replication-backend:5984" "$path/config/aam-backend-service/application.env"
setEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH "https://pdf.aam-digital.dev" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID "$RENDER_API_CLIENT_ID_DEV" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET "$RENDER_API_CLIENT_SECRET_DEV" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT "https://auth.aam-digital.dev/realms/aam-digital/protocol/openid-connect/token" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE "client_credentials" "$path/config/aam-backend-service/application.env"
setEnv SENTRY_AUTH_TOKEN "$SENTRY_AUTH_TOKEN" "$path/config/aam-backend-service/application.env"
setEnv SENTRY_DSN "$SENTRY_DSN_BACKEND" "$path/config/aam-backend-service/application.env"
setEnv SENTRY_SERVER_NAME "$instance.$DOMAIN" "$path/config/aam-backend-service/application.env"

# create aam-backend Keycloak client for permission checks
if ! createKeycloakBackendClient "$instance"; then
  echo "ERROR: Failed to create/get Keycloak backend client for '$instance'. Aborting."
  exit 1
fi
if [ -z "$clientSecret" ]; then
  echo "ERROR: Keycloak client created but secret could not be retrieved for '$instance'. Aborting."
  exit 1
fi

# ensure key exists before setting (older .env templates may lack it)
if ! grep -q '^REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=' "$path/.env"; then
  echo "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=" >> "$path/.env"
fi
setEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$clientSecret" "$path/.env"

setEnv COMPOSE_PROFILES "full-stack" "$path/.env"

(cd "$path" && docker compose up -d)

echo "Backend enabled."
