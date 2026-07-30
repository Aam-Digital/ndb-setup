#!/bin/bash

# Migration script: wires Carbone PDF render API access for aam-backend-service.
#
# enable-backend.sh now registers this client itself for newly created instances, so this script is
# mainly needed for instances created before that fix (or ones still on the old shared dev client).
#
# For each full-stack instance:
# - Creates a Keycloak client `carbone-<instance>` in the central `aam-platform` realm
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

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

##############################
# Configuration
##############################

# CARBONE_REALM and OAUTH2_PROXY_CLIENT_ID come from lib/keycloak.sh (sourced above).

# CARBONE_HOST must be set in setup.env. It is the public hostname of the Carbone
# deployment for this environment — NOT derived from the instance's own DOMAIN.
if [[ -z "${CARBONE_HOST:-}" ]]; then
  echo "ERROR: CARBONE_HOST is not set in setup.env."
  echo "  Staging:    CARBONE_HOST=pdf.dev-cluster.aam-digital.net"
  echo "  Production: CARBONE_HOST=pdf.aam-digital.app"
  exit 1
fi

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
# migrate one instance
##############################

# ensureAudienceMapper() and createCarboneRenderClient() are provided by lib/keycloak.sh (sourced above).

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

  # Check if already fully migrated.
  # Dynamic vars (BASE_PATH, CLIENT_ID, CLIENT_SECRET, TOKEN_ENDPOINT) only need a non-empty value.
  # Static vars are validated against their expected values so an empty or stale value triggers re-migration.
  local needsMigration=false
  for var in AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT; do
    if ! grep -qE "^$var=.+" "$appEnvFile" 2>/dev/null; then
      needsMigration=true
      break
    fi
  done
  # Static vars: validate exact expected values
  if [ "$needsMigration" = false ]; then
    grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE=client_credentials$" "$appEnvFile" 2>/dev/null || needsMigration=true
    grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE=openid$"                 "$appEnvFile" 2>/dev/null || needsMigration=true
    grep -q "^FEATURES_EXPORT_API_ENABLED=true$"                                             "$appEnvFile" 2>/dev/null || needsMigration=true
  fi

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
