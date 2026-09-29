#!/bin/bash

# Migration script: grants the "account_manager" realm role the realm-management roles it needs,
# so that users with that role can manage roles in the app's "Roles & Permissions" admin UI.
#
# The UI calls the Keycloak admin API directly from the frontend, so this applies to every instance,
# not only full-stack ones.
#
# For each instance:
# - Adds any missing realm-management roles (view-realm, manage-users, manage-realm) to the
#   "account_manager" realm role of the instance's realm
#
# Users must log out and back in afterwards, since the capability is read from the access token.
#
# Usage:
#   ./migrate-account-manager-manage-realm.sh                # migrate all instances
#   ./migrate-account-manager-manage-realm.sh <instance>     # migrate single instance
#
# KEYCLOAK_HOST/KEYCLOAK_USER/KEYCLOAK_PASSWORD come from setup.env, or are fetched via
# BWS_ACCESS_TOKEN if they are not all set there.

set -uo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

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
# migrate one instance
##############################

failedInstances=()

migrateInstance() {
  local instanceDir="$1"
  local instance
  instance=$(getVar "$instanceDir/.env" INSTANCE_NAME)
  if [ -z "$instance" ]; then
    instance="$(basename "$instanceDir")"
    instance="${instance#"${PREFIX:-}"}"
  fi

  token=""   # the admin token is short-lived, get a fresh one for each instance

  if accountManagerHasRealmManagementRoles "$instance" "${ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "[$instance] already up-to-date, skipping"
    return 0
  fi

  echo "[$instance] migrating..."
  if ! ensureAccountManagerRealmManagementRoles "$instance"; then
    failedInstances+=("$instance")
    return 0
  fi

  if ! accountManagerHasRealmManagementRoles "$instance" "${ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "  ERROR: Could not confirm the realm-management roles on 'account_manager'."
    failedInstances+=("$instance")
    return 0
  fi
  echo "[$instance] done"
}

##############################
# main
##############################

forEachInstance migrateInstance "${1:-}" || exit 1

if [ "${#failedInstances[@]}" -gt 0 ]; then
  echo "Migration failed for: ${failedInstances[*]}"
  exit 1
fi

echo "Migration complete. Affected users need to log out and back in."
