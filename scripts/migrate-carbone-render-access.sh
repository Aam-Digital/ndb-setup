#!/bin/bash

# Migration script: wires Carbone PDF render API access for aam-backend-service.
#
# For each full-stack instance:
# - Creates a Keycloak client `<instance>-render` in the central `aam-platform` realm
#   (one client per tenant — see aam-cloud-infrastructure/infra/src/aam-platform/README.md)
# - Adds AAM_RENDER_API_CLIENT_CONFIGURATION_* + FEATURES_EXPORT_API_ENABLED=true to application.env
# - Restarts the instance
#
# Usage:
#   ./migrate-carbone-render-access.sh                # migrate all instances
#   ./migrate-carbone-render-access.sh <instance>     # migrate single instance
#
# Requires: CARBONE_HOST and KEYCLOAK_HOST set in setup.env (environment-specific):
#
#   Environment  KEYCLOAK_HOST                  CARBONE_HOST
#   -----------  -----------------------------  --------------------------------
#   Staging      keycloak.aam-digital.net        pdf.dev-cluster.aam-digital.net
#   Production   keycloak.aam-digital.com        pdf.aam-digital.app
#
# KEYCLOAK_HOST may also be fetched automatically via BWS_ACCESS_TOKEN instead of
# setting it directly in setup.env (KEYCLOAK_USER/KEYCLOAK_PASSWORD are also needed then).
# Requires: the `aam-platform` realm to already exist on the central Keycloak.

set -uo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

##############################
# Configuration
##############################

CARBONE_REALM="aam-platform"

# CARBONE_HOST must be set in setup.env. It is the public hostname of the Carbone
# deployment for this environment — NOT derived from the instance's own DOMAIN.
if [[ -z "${CARBONE_HOST:-}" ]]; then
  echo "ERROR: CARBONE_HOST is not set in setup.env."
  echo "  Staging:    CARBONE_HOST=pdf.dev-cluster.aam-digital.net"
  echo "  Production: CARBONE_HOST=pdf.aam-digital.app"
  exit 1
fi

# oauth2-proxy client ID — render clients must include this in their token audience.
OAUTH2_PROXY_CLIENT_ID="carbone-oauth2-proxy"

##############################
# BWS secrets (skipped if KEYCLOAK_HOST/USER/PASSWORD are already set in setup.env)
##############################

if [[ -z "${KEYCLOAK_HOST:-}" ]] || [[ -z "${KEYCLOAK_USER:-}" ]] || [[ -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    echo "BWS_ACCESS_TOKEN is not set and KEYCLOAK_HOST/KEYCLOAK_USER/KEYCLOAK_PASSWORD are not all set. Abort."
    exit 1
  fi

  bws config server-base https://vault.bitwarden.eu

  KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
  KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
  KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)
fi

##############################
# Preflight: confirm `aam-platform` realm exists on the central Keycloak
##############################

checkServicesRealmExists() {
  if ! getKeycloakToken; then
    return 1
  fi
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "https://$KEYCLOAK_HOST/admin/realms/$CARBONE_REALM" \
    -H "Authorization: Bearer $token")
  if [ "$status" != "200" ]; then
    echo "ERROR: Realm '$CARBONE_REALM' not found on $KEYCLOAK_HOST (HTTP $status)."
    echo "Create it first — see aam-cloud-infrastructure/infra/src/aam-platform/README.md > Initial setup."
    return 1
  fi
}

##############################
# Ensure an audience mapper on the given client includes OAUTH2_PROXY_CLIENT_ID
# in the access-token `aud` claim (idempotent — checked by mapper name).
# oauth2-proxy rejects bearer tokens without this audience.
# Args: realm, clientUuid
##############################

ensureAudienceMapper() {
  local realm="$1"
  local clientUuid="$2"
  local mapperName="audience-${OAUTH2_PROXY_CLIENT_ID}"

  local existing
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/protocol-mappers/models" \
    -H "Authorization: Bearer $token" | jq -r --arg n "$mapperName" '.[] | select(.name == $n) | .id // empty')

  if [ -n "$existing" ]; then
    echo "  audience mapper already present on client."
    return 0
  fi

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/protocol-mappers/models" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$mapperName\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"config\": {
        \"included.client.audience\": \"$OAUTH2_PROXY_CLIENT_ID\",
        \"id.token.claim\": \"false\",
        \"access.token.claim\": \"true\",
        \"introspection.token.claim\": \"true\",
        \"userinfo.token.claim\": \"false\"
      }
    }")

  if [ "$status" != "201" ]; then
    echo "  ERROR: failed to add audience mapper (HTTP $status)."
    return 1
  fi
  echo "  Added audience mapper for $OAUTH2_PROXY_CLIENT_ID."
}

##############################
# Create a render client in the central aam-platform realm
# Args: realm, clientId
# Sets: clientSecret (global)
##############################

createCarboneRenderClient() {
  local realm="$1"
  local clientId="$2"
  clientSecret=""

  if ! getKeycloakToken; then
    return 1
  fi

  # check if client already exists
  local existing existingUuid
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=$clientId" \
    -H "Authorization: Bearer $token")
  existingUuid=$(echo "$existing" | jq -r '.[0].id // empty')

  if [ -n "$existingUuid" ]; then
    echo "  $clientId client already exists in realm $realm: $existingUuid"
    clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$existingUuid/client-secret" \
      -H "Authorization: Bearer $token" | jq -r '.value // empty')
    ensureAudienceMapper "$realm" "$existingUuid" || return 1
    return 0
  fi

  # create the client: confidential, service-account only (no interactive flows)
  local clientResponse location clientUuid
  clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/clients" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"$clientId\",
      \"enabled\": true,
      \"clientAuthenticatorType\": \"client-secret\",
      \"serviceAccountsEnabled\": true,
      \"publicClient\": false,
      \"standardFlowEnabled\": false,
      \"directAccessGrantsEnabled\": false,
      \"protocol\": \"openid-connect\"
    }")

  location=$(echo "$clientResponse" | grep -i "^location:")
  clientUuid=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

  if [ -z "$clientUuid" ]; then
    echo "  ERROR: Failed to create $clientId client in realm '$realm'."
    return 1
  fi

  echo "  Created $clientId client: $clientUuid"

  clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/client-secret" \
    -H "Authorization: Bearer $token" | jq -r '.value // empty')

  if [ -z "$clientSecret" ]; then
    echo "  ERROR: Failed to retrieve client secret for $clientId in realm '$realm'."
    return 1
  fi

  ensureAudienceMapper "$realm" "$clientUuid" || return 1
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

  # only full-stack instances consume the render API (aam-backend-service is the client)
  if [ "$profile" != "full-stack" ]; then
    echo "[$instance] profile=$profile — skipping (not full-stack)"
    return
  fi

  if [ ! -f "$appEnvFile" ]; then
    echo "[$instance] no application.env found — skipping (backend not configured)"
    return
  fi

  # Check if already fully migrated
  local needsMigration=false
  for var in AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE \
             FEATURES_EXPORT_API_ENABLED; do
    if ! grep -q "^$var=" "$appEnvFile" 2>/dev/null; then
      needsMigration=true
      break
    fi
  done

  # Also migrate if the token endpoint still points to the old shared aam-digital realm
  # (instances set up with enable-backend.sh have this value and need updating).
  if grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT=.*/realms/aam-digital/" "$appEnvFile" 2>/dev/null; then
    needsMigration=true
  fi

  if [ "$needsMigration" = false ]; then
    echo "[$instance] already up-to-date, skipping"
    return
  fi

  echo "[$instance] migrating..."

  # 0. Create the Keycloak render client (or fetch existing).
  # Do this before modifying local files so failures do not leave a partial migration behind.
  local clientId="carbone-${instance}"
  if ! createCarboneRenderClient "$CARBONE_REALM" "$clientId"; then
    echo "  ERROR: Failed to create or fetch Keycloak render client. Skipping."
    return 1
  fi
  if [ -z "$clientSecret" ]; then
    echo "  ERROR: render client created/fetched but secret could not be retrieved. Skipping."
    return 1
  fi

  # 1. Backup application.env
  backupFile "$appEnvFile"

  # 2. Set render API config in application.env (ensureEnv adds the key if absent, setEnv overwrites any stale value)
  local tokenEndpoint="https://$KEYCLOAK_HOST/realms/$CARBONE_REALM/protocol/openid-connect/token"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH" "https://$CARBONE_HOST" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH" "https://$CARBONE_HOST" "$appEnvFile"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID" "$clientId" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID" "$clientId" "$appEnvFile"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET" "$clientSecret" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET" "$clientSecret" "$appEnvFile"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT" "$tokenEndpoint" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT" "$tokenEndpoint" "$appEnvFile"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE" "client_credentials" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE" "client_credentials" "$appEnvFile"
  ensureEnv "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE" "openid" "$appEnvFile"
  setEnv    "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE" "openid" "$appEnvFile"
  ensureEnv "FEATURES_EXPORT_API_ENABLED" "true" "$appEnvFile"

  # 3. Restart so aam-backend-service picks up the new config
  echo "  Restarting..."
  (cd "$instanceDir" && docker compose down && docker compose up -d)

  echo "[$instance] done"
  echo ""
}

##############################
# main
##############################

if ! checkServicesRealmExists; then
  exit 1
fi

if [ -n "${1:-}" ]; then
  # single instance mode
  path="$baseDirectory/${PREFIX:-}$1"
  if [ ! -d "$path" ]; then
    echo "Instance directory not found: $path"
    exit 1
  fi
  migrate_instance "$path"
else
  # all instances
  if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set. Aborting to avoid operating on all directories."
    exit 1
  fi
  cd "$baseDirectory"
  for D in ${PREFIX}*; do
    if [ -d "$D" ]; then
      migrate_instance "$baseDirectory/$D"
    fi
  done
fi

echo "Migration complete."
