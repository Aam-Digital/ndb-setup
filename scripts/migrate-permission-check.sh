#!/bin/bash

# Migration script: adds Keycloak service account for replication-backend permission checks.
#
# For each instance:
# - Adds REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID / SECRET to .env
# - For full-stack instances: creates the aam-backend Keycloak client with manage-realm role
# - For full-stack instances: ensures AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTH* vars exist in application.env
#
# Usage:
#   ./migrate-permission-check.sh                # migrate all instances
#   ./migrate-permission-check.sh <instance>      # migrate single instance
#
# Requires: BWS_ACCESS_TOKEN set in environment or setup.env

set -uo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

##############################
# BWS secrets
##############################

if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
  echo "BWS_ACCESS_TOKEN is not set. Abort."
  exit 1
fi

bws config server-base https://vault.bitwarden.eu

KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)

##############################
# helpers
##############################

getVar() {
  local file="$1"
  local var="$2"
  grep "^$var=" "$file" 2>/dev/null | cut -d '=' -f2- || echo ""
}

setEnv() {
  local key="$1"
  local value="$2"
  local file="$3"
  sed -i "s|^$key=.*|$key=$value|g" "$file"
}

# Append a variable to a file if it does not already exist
ensureEnv() {
  local key="$1"
  local value="$2"
  local file="$3"
  if ! grep -q "^$key=" "$file" 2>/dev/null; then
    echo "$key=$value" >> "$file"
    echo "  + added $key to $(basename "$file")"
  fi
}

getKeycloakToken() {
  local raw
  raw=$(curl -s -L "https://$KEYCLOAK_HOST/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode username="$KEYCLOAK_USER" \
    --data-urlencode password="$KEYCLOAK_PASSWORD" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli)
  token=${raw#*\"access_token\":\"}
  token=${token%%\"*}

  if [ -z "$token" ] || [ "$token" = "$raw" ]; then
    echo "  ERROR: Failed to get Keycloak admin token."
    return 1
  fi
}

# Creates the aam-backend Keycloak client (if it doesn't exist) and assigns manage-realm role.
# Sets $clientSecret on success.
createOrGetKeycloakBackendClient() {
  local realm="$1"
  clientSecret=""

  getKeycloakToken

  # check if aam-backend client already exists
  local existing
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=aam-backend" \
    -H "Authorization: Bearer $token")
  local existingUuid
  existingUuid=$(echo "$existing" | jq -r '.[0].id // empty')

  if [ -n "$existingUuid" ]; then
    echo "  aam-backend client already exists: $existingUuid"
    clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$existingUuid/client-secret" \
      -H "Authorization: Bearer $token" | jq -r '.value // empty')

    # ensure service account has manage-realm role (idempotent)
    assignManageRealmRole "$realm" "$existingUuid"
    return 0
  fi

  # create the aam-backend client (confidential, service account enabled)
  local clientResponse
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

  local location clientUuid
  location=$(echo "$clientResponse" | grep -i "^location:")
  clientUuid=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

  if [ -z "$clientUuid" ]; then
    echo "  ERROR: Failed to create aam-backend client in realm '$realm'."
    return 1
  fi

  echo "  Created aam-backend client: $clientUuid"

  clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/client-secret" \
    -H "Authorization: Bearer $token" | jq -r '.value // empty')

  assignManageRealmRole "$realm" "$clientUuid"
}

assignManageRealmRole() {
  local realm="$1"
  local aamBackendClientUuid="$2"

  local serviceAccountUserId
  serviceAccountUserId=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$aamBackendClientUuid/service-account-user" \
    -H "Authorization: Bearer $token" | jq -r '.id // empty')

  if [ -z "$serviceAccountUserId" ]; then
    echo "  WARNING: Could not get service account user for aam-backend client."
    return 1
  fi

  local realmMgmtClientUuid
  realmMgmtClientUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=realm-management" \
    -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

  local manageRealmRole
  manageRealmRole=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$realmMgmtClientUuid/roles/manage-realm" \
    -H "Authorization: Bearer $token")

  curl -s -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/users/$serviceAccountUserId/role-mappings/clients/$realmMgmtClientUuid" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "[$manageRealmRole]"

  echo "  Ensured manage-realm role on aam-backend service account."
}

##############################
# migrate one instance
##############################

migrate_instance() {
  local instanceDir="$1"
  local instance
  instance=$(basename "$instanceDir")
  instance=${instance#"$PREFIX"}

  local envFile="$instanceDir/.env"
  local appEnvFile="$instanceDir/config/aam-backend-service/application.env"

  if [ ! -f "$envFile" ]; then
    echo "[$instance] no .env file, skipping"
    return
  fi

  local profile
  profile=$(getVar "$envFile" COMPOSE_PROFILES)

  # only full-stack instances need migration (permission check is only used by aam-backend-service)
  if [ "$profile" != "full-stack" ]; then
    echo "[$instance] profile=$profile — skipping (not full-stack)"
    return
  fi

  echo "[$instance] migrating..."

  # 1. Add Keycloak vars to .env (for replication-backend)
  ensureEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID" "aam-backend" "$envFile"
  ensureEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET" "" "$envFile"

  # 2. Create aam-backend Keycloak client (or get existing) + assign manage-realm
  if createOrGetKeycloakBackendClient "$instance"; then
    if [ -n "$clientSecret" ]; then
      setEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET" "$clientSecret" "$envFile"
      echo "  Set REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET in .env"
    else
      echo "  WARNING: Could not retrieve client secret"
    fi
  fi

  # 3. Ensure application.env has replication-backend basic auth vars
  if [ -f "$appEnvFile" ]; then
    local couchUser couchPass
    couchUser=$(getVar "$envFile" COUCHDB_USER)
    couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)

    ensureEnv "AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME" "$couchUser" "$appEnvFile"
    ensureEnv "AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD" "$couchPass" "$appEnvFile"
  else
    echo "  no application.env found — skipping aam-backend-service config"
  fi

  # 4. Restart
  echo "  Restarting..."
  (cd "$instanceDir" && docker compose down && docker compose pull && docker compose up -d)

  echo "[$instance] done"
  echo ""
}

##############################
# main
##############################

if [ -n "${1:-}" ]; then
  # single instance mode
  path="$baseDirectory/$PREFIX$1"
  if [ ! -d "$path" ]; then
    echo "Instance directory not found: $path"
    exit 1
  fi
  migrate_instance "$path"
else
  # all instances
  cd "$baseDirectory"
  for D in ${PREFIX}*; do
    if [ -d "$D" ]; then
      migrate_instance "$baseDirectory/$D"
    fi
  done
fi

echo "Migration complete."
