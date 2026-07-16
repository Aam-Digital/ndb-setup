#!/bin/bash

# Migration script: declare `exact_username` as an admin-only User Profile
# attribute in every Keycloak realm (Keycloak 26 upgrade follow-up).
#
# Why:
#   Keycloak 26's in-place migration upgrades the DB schema and restores the
#   `sub` claim automatically (via the `basic` client scope), but it does NOT
#   add custom User Profile attributes to existing realms. `exact_username`
#   stores the entity id linked to a user account; it must be view-able by
#   admin+user but edit-able by admins only (a user changing their own linked
#   id is a permission-escalation loophole). This declares it on every realm.
#
#   Existing `exact_username` values are preserved regardless; this only locks
#   down WHO may edit them. The migration does NOT retro-apply this to existing
#   realms, so it is required for every realm upgraded in place. Fresh realms
#   already get it from realm_config.json. Manual alternative to this script:
#   apply the User Profile declaration per realm via the Admin Console
#   (Realm settings -> User profile) or by re-importing the realm config.
#
# Unlike the other migrate-*.sh scripts (which loop instance directories under
# /var/docker), this loops Keycloak realms via the Admin API, because the User
# Profile is a per-realm setting on the single shared Keycloak and we want to
# cover every realm — including ones without an instance dir (aam-platform,
# test realms, ...).
#
# Safe to re-run: realms that already declare exact_username are skipped, and
# the existing profile is read + appended (existing attributes preserved).
# DRY-RUN by default; pass --apply to write.
#
# Usage:
#   ./migrate-keycloak26-exact-username-userprofile.sh                 # dry-run, all realms
#   ./migrate-keycloak26-exact-username-userprofile.sh --apply         # write, all realms
#   ./migrate-keycloak26-exact-username-userprofile.sh --realm acme    # dry-run, single realm
#   ./migrate-keycloak26-exact-username-userprofile.sh --realm acme --apply
#   ./migrate-keycloak26-exact-username-userprofile.sh --include-master --apply
#
# Credentials: set KEYCLOAK_HOST / KEYCLOAK_USER / KEYCLOAK_PASSWORD in the
# environment to run ad-hoc; otherwise they are fetched from Bitwarden (BWS),
# same as the other migration scripts (requires BWS_ACCESS_TOKEN).
#
# Requires: bash, curl, jq

set -uo pipefail

baseDirectory="${baseDirectory:-/var/docker}"
[ -f "$baseDirectory/ndb-setup/setup.env" ] && source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

##############################
# args
##############################

APPLY=false
ONE_REALM=""
INCLUDE_MASTER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)          APPLY=true ;;
    --realm)          ONE_REALM="${2:?--realm needs a value}"; shift ;;
    --include-master) INCLUDE_MASTER=true ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

##############################
# credentials (env override, else BWS like the sibling scripts)
##############################

if [[ -z "${KEYCLOAK_HOST:-}" || -z "${KEYCLOAK_USER:-}" || -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    echo "ERROR: set KEYCLOAK_HOST/KEYCLOAK_USER/KEYCLOAK_PASSWORD, or BWS_ACCESS_TOKEN for Bitwarden." >&2
    exit 1
  fi
  bws config server-base https://vault.bitwarden.eu
  KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
  KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
  KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)
fi

# The attribute to declare. admin+user may VIEW; only admin may EDIT.
EXACT_USERNAME_ATTR='{
  "name": "exact_username",
  "displayName": "Aam Digital user profile ID",
  "permissions": { "view": ["admin","user"], "edit": ["admin"] },
  "multivalued": false
}'

##############################
# migrate one realm
##############################

n_total=0; n_skip=0; n_change=0; n_err=0

migrate_realm() {
  local realm="$1"
  n_total=$((n_total+1))

  # fresh token per realm (admin token lifespan can be short across many realms)
  if ! getKeycloakToken; then
    echo "[$realm] ERROR — could not obtain admin token"
    n_err=$((n_err+1)); return
  fi

  local profile
  profile=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/users/profile" \
    -H "Authorization: Bearer $token")

  if ! echo "$profile" | jq -e '.attributes' >/dev/null 2>&1; then
    echo "[$realm] ERROR — could not read user profile"
    n_err=$((n_err+1)); return
  fi

  if echo "$profile" | jq -e '.attributes[]?|select(.name=="exact_username")' >/dev/null 2>&1; then
    echo "[$realm] = already declared, skipping"
    n_skip=$((n_skip+1)); return
  fi

  if [ "$APPLY" = false ]; then
    echo "[$realm] would add exact_username (dry-run)"
    n_change=$((n_change+1)); return
  fi

  local new_profile code
  new_profile=$(echo "$profile" | jq --argjson a "$EXACT_USERNAME_ATTR" '.attributes += [$a]')
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "https://$KEYCLOAK_HOST/admin/realms/$realm/users/profile" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$new_profile")

  if [[ "$code" =~ ^2 ]]; then
    echo "[$realm] + added exact_username"
    n_change=$((n_change+1))
  else
    echo "[$realm] ERROR — PUT users/profile returned HTTP $code"
    n_err=$((n_err+1))
  fi
}

##############################
# main
##############################

$APPLY && echo "MODE: APPLY (writing changes)" || echo "MODE: DRY-RUN (no changes; pass --apply to write)"
echo "Keycloak: https://$KEYCLOAK_HOST"
echo "-------------------------------------------------------------"

if [ -n "$ONE_REALM" ]; then
  migrate_realm "$ONE_REALM"
else
  if ! getKeycloakToken; then
    echo "ERROR: could not obtain admin token to list realms." >&2
    exit 1
  fi
  realms=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms" \
    -H "Authorization: Bearer $token" | jq -r '.[].realm')
  for realm in $realms; do
    if [ "$realm" = "master" ] && [ "$INCLUDE_MASTER" = false ]; then
      continue
    fi
    migrate_realm "$realm"
  done
fi

echo "-------------------------------------------------------------"
echo "realms processed: $n_total | already-ok: $n_skip | changed: $n_change | errors: $n_err"
$APPLY || echo "DRY-RUN: re-run with --apply to write the changes above."
