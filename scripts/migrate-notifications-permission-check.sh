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
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

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

  # Check if already fully migrated
  local needsMigration=false
  if ! grep -q "^REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID=" "$envFile" 2>/dev/null; then
    needsMigration=true
  elif ! grep -q "^REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=" "$envFile" 2>/dev/null; then
    needsMigration=true
  elif [ -f "$appEnvFile" ]; then
    for var in AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH \
               AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME \
               AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD; do
      if ! grep -q "^$var=" "$appEnvFile" 2>/dev/null; then
        needsMigration=true
        break
      fi
    done
  fi

  if [ "$needsMigration" = false ]; then
    echo "[$instance] already up-to-date, skipping"
    return
  fi

  echo "[$instance] migrating..."

  # backup files before any modification
  backupFile "$envFile"
  backupFile "$instanceDir/docker-compose.yml"
  [ -f "$appEnvFile" ] && backupFile "$appEnvFile"

  # 0. Create aam-backend Keycloak client (or get existing) + assign manage-realm
  # Do this before modifying local files so failures do not leave a partial migration behind.
  if createKeycloakBackendClient "$instance"; then
    if [ -z "$clientSecret" ]; then
      echo "  ERROR: Client created/fetched but secret could not be retrieved."
      echo "  Skipping migration for $instance to avoid broken permission-check config."
      return 1
    fi
  else
    echo "  ERROR: Failed to create or get Keycloak backend client for $instance."
    echo "  Skipping migration for this instance to avoid broken permission-check config."
    return 1
  fi

  # 1. Update docker-compose.yml from shared ndb-setup template
  cp "$baseDirectory/ndb-setup/docker-compose.yml" "$instanceDir/docker-compose.yml"
  echo "  Updated docker-compose.yml from ndb-setup template"

  # 2. Add Keycloak vars to .env (for replication-backend)
  ensureEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID" "aam-backend" "$envFile"
  ensureEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET" "$clientSecret" "$envFile"
  setEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET" "$clientSecret" "$envFile"

  # 3. Ensure application.env has replication-backend basic auth vars
  if [ -f "$appEnvFile" ]; then
    local couchUser couchPass
    couchUser=$(getVar "$envFile" COUCHDB_USER)
    couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)

    ensureEnv "AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH" "http://replication-backend:5984" "$appEnvFile"
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
