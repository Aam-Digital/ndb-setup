#!/bin/bash

# This script will enable the backend for an customer instance.
# All needed credentials are loaded/stored from/to the Bitwarden Secrets Manager

# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./enable-backend.sh <instance>
# example: ./enable-backend.sh qm
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#

##############################
# setup
##############################

source "../setup.env"

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

path="../../$PREFIX$instance"

# load secrets from Bitwarden Secret Manager
RENDER_API_CLIENT_ID_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b53d7a1d-220e-4e07-b1f9-b22700711f79" | jq -r .value)
RENDER_API_CLIENT_SECRET_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "83a8e38b-fc22-461f-91a0-b22700712b62" | jq -r .value)
SENTRY_AUTH_TOKEN=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b9a3e1eb-3925-4ed6-93f4-b2270073c82c" | jq -r .value)
SENTRY_DSN_BACKEND=$(bws secret -t "$BWS_ACCESS_TOKEN" get "a858a580-9643-4330-8667-b2270073d7a6" | jq -r .value)

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789

isBackendEnabled=0
isBackendConfigCreated=0
isReplicationBackendEnabled=0

# setting backend version. Pinned to prevent config conflicts
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
  backendVersion=$(curl -s -L "curl -s https://api.github.com/repos/Aam-Digital/aam-services/tags | jq -r 'map(select(.name | test(\"^aam-backend-service/\"))) | .[0].name | split(\"/\") | .[1]'" -H 'Accept: application/json')
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

    sed -i "s|^$key=.*|$key=$value|g" "$path" # linux
    # gsed -i "s|^$key=.*|$key=$value|g" "$path" # macos
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
curl -L -o "$path/config/aam-backend-service/application.env" "https://github.com/Aam-Digital/aam-services/blob/aam-backend-service/$backendVersion/templates/aam-backend-service/application.template.env"

generate_password

setEnv CRYPTO_CONFIGURATION_SECRET "$password" "$path/config/aam-backend-service/application.env"
setEnv SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI "https://keycloak.$DOMAIN/realms/$instance" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_USERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_PASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
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

setEnv COMPOSE_PROFILES "full-stack" "$path/.env"

(cd "$path" && docker compose up -d)

echo "Backend enabled."
