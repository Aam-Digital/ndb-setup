#!/bin/bash

# Configure CouchDB for an instance: write couchdb.ini (with or without the JWT signing key, depending on
# mode - see below), start the database, create the required databases and apply the document-level
# _security appropriate for the mode: "user_app" as database admin and member for a directly-exposed
# database-only instance, or admin-only (resetting any previously-applied "user_app" grant) when
# replication-backend fronts it.
# Idempotent: couchdb.ini is regenerated from the template each run, database creation tolerates existing
# databases, and _security is always (re)applied for the current mode, not just applied-once. Reads
# everything it needs from the instance .env — no secrets.
#
# Safe to run on a live instance, so it also works as a repair/migration: an already-running CouchDB is
# reused (not removed) and only restarted if couchdb.ini actually changed.
#
# Usage:
#   ./create-couchdb.sh <instance> [--with-permissions]
#   ./create-couchdb.sh --repair-all
#
# <instance>           an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the
#                      instance directory (e.g. "." when run from inside it, or /any/path/to/instance)
# --with-permissions   the replication-backend enforces access, so CouchDB stays internal: _security is
#                      reset to admin-only, anonymous requests are rejected (except /_up, for the
#                      healthcheck) and couchdb-with-permissions.ini omits the JWT signing key - CouchDB's own
#                      JWT auth is dead config once nothing talks to it directly. Without the flag, the mode
#                      is detected from COMPOSE_PROFILES in the instance .env (the flag is needed while
#                      setting up an instance whose profile is not switched yet). Database-only mode
#                      (CouchDB exposed directly) applies the "user_app" _security and the JWT signing key.
# --repair-all         run this for every instance, each in its detected mode; takes no other arguments

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"
source "$scriptDir/lib/couchdb.sh"

##############################
# parse flags
##############################

withPermissions=false
repairAll=false
positionalArgs=()
for arg in "$@"; do
  case "$arg" in
    --with-permissions) withPermissions=true ;;
    --repair-all) repairAll=true ;;
    *) positionalArgs+=("$arg") ;;
  esac
done
set -- "${positionalArgs[@]+"${positionalArgs[@]}"}"

##############################
# --repair-all
##############################

# Each instance runs in its own subprocess: the per-instance path exits on errors and sets globals, which
# must neither abort the loop nor leak into the next instance.
if [ "$repairAll" = true ]; then
  if [ "$#" -gt 0 ] || [ "$withPermissions" = true ]; then
    echo "ERROR: --repair-all repairs all instances in their detected mode and takes no other arguments (got: $*)."
    echo "  To repair a single instance, run: $0 <instance>"
    exit 1
  fi
  failedInstances=()
  repairInstance() {
    local dir="$1"
    echo "[$(basename "$dir")]"
    "$0" "$dir" || failedInstances+=("$(basename "$dir")")
    echo ""
  }
  forEachInstance repairInstance || exit 1
  if [ "${#failedInstances[@]}" -gt 0 ]; then
    echo "Repair failed for: ${failedInstances[*]}"
    exit 1
  fi
  exit 0
fi

##############################
# input
##############################

if [ -n "$1" ]; then
  instanceArg="$1"
else
  echo "Which instance? (name, or path to the instance directory, e.g. '.')"
  read -r instanceArg
fi
resolveInstancePath "$instanceArg" || exit 1
if [ ! -d "$path" ]; then
  echo "ERROR: instance directory not found: $path (run create-instance.sh first). Abort."
  exit 1
fi
org=$(getVar "$path/.env" INSTANCE_NAME)

# The profiles that deploy replication-backend; unset/empty behaves like database-only (no profile active).
composeProfiles=$(getVar "$path/.env" COMPOSE_PROFILES)
case "$composeProfiles" in
  with-permissions | full-stack | full-stack-without-sqs) withPermissions=true ;;
esac
if [ "$withPermissions" = true ]; then
  echo "Configuring CouchDB for '$org' (with-permissions: replication-backend enforces access)"
else
  echo "Configuring CouchDB for '$org' (database-only: CouchDB exposed directly)"
fi

couchDbUser=$(getVar "$path/.env" COUCHDB_USER)
couchDbPassword=$(getVar "$path/.env" COUCHDB_PASSWORD)

if [ -z "$couchDbUser" ] || [ -z "$couchDbPassword" ]; then
  echo "ERROR: COUCHDB_USER / COUCHDB_PASSWORD missing in $path/.env. Abort."
  exit 1
fi

##############################
# couchdb.ini (JWT signing key)
##############################

# Regenerate from the pristine template each run (the template is static apart from the key placeholders),
# which keeps the substitution idempotent and update-safe even if the key rotated.
#
# [jwt_keys] / jwt_authentication_handler are only meaningful in database-only mode, where the browser
# talks to CouchDB directly and CouchDB must validate the user's Keycloak JWT itself. With replication-backend
# in front (--with-permissions), every client here uses basic auth - CouchDB's own JWT auth is dead config in
# that mode, and a realm role literally named "_admin" would make it a live server-admin bypass (Keycloak's
# realm-role mapper copies realm roles verbatim onto the _couchdb.roles claim CouchDB checks for that). So
# with-permissions uses a template with no [jwt_keys]/[jwt_auth] section and no jwt_authentication_handler.
newIni=$(mktemp)
trap 'rm -f "$newIni"' EXIT
if [ "$withPermissions" = true ]; then
  cp "$ndbSetupDir/couchdb-with-permissions.ini" "$newIni"
else
  kid=$(getVar "$path/.env" KEYCLOAK_JWT_KID)
  publicKey=$(getVar "$path/.env" REPLICATION_BACKEND_PUBLIC_KEY)
  if [ -z "$kid" ] || [ -z "$publicKey" ]; then
    echo "ERROR: KEYCLOAK_JWT_KID / REPLICATION_BACKEND_PUBLIC_KEY missing in $path/.env."
    echo "  Run create-keycloak-realm.sh first. Abort."
    exit 1
  fi
  cp "$ndbSetupDir/couchdb.ini" "$newIni"
  # '|' delimiter avoids clashing with '/' in a base64 key; escape sed-special chars in the value
  escapedKey=$(printf '%s' "$publicKey" | sed 's/[\\&|]/\\&/g')
  sed -i "s|<KID>|$kid|g" "$newIni"
  sed -i "s|<PUBLIC_KEY>|$escapedKey|g" "$newIni"
fi

# Written in place (not replaced), so the bind-mounted file keeps its owner.
iniChanged=false
if ! cmp -s "$newIni" "$path/couchdb.ini"; then
  cat "$newIni" > "$path/couchdb.ini"
  iniChanged=true
  if [ "$withPermissions" = true ]; then
    echo "  ~ wrote couchdb.ini (with-permissions: no JWT signing key, anonymous requests rejected)"
  else
    echo "  ~ wrote couchdb.ini (with JWT signing key)"
  fi
else
  echo "  couchdb.ini already up to date"
fi

##############################
# start database + create databases
##############################

echo "Starting CouchDB for '$org'..."
couchdbInitStart || exit 1

# A reused, already-running CouchDB only reads couchdb.ini on startup.
if [ "$DB_REUSED_RUNNING" = true ] && [ "$iniChanged" = true ]; then
  echo "  ~ restarting the running CouchDB to apply couchdb.ini"
  couchdbRestart || exit 1
fi

# create the required databases (201 = created, 412 = already exists; anything else is a real failure)
for db in _users app report-calculation notification-webhook app-attachments; do
  status=$(couchdbCurl -X PUT "$DB_LOCAL_URL/$db" -o /dev/null -w "%{http_code}")
  if [ "$status" != "201" ] && [ "$status" != "412" ]; then
    echo "ERROR: failed to create database '$db' (HTTP $status). Abort."
    couchdbInitStop
    exit 1
  fi
  echo "  ensured database '$db'"
done

# For a database-only instance CouchDB is exposed directly, so restrict app / app-attachments to the
# "user_app" role. With the replication-backend (--with-permissions) CouchDB is internal and the backend
# enforces access, so _security must be reset to admin-only there instead - explicitly, in both directions,
# not just "skip applying the permissive one". Nothing else clears a permissive _security document once
# written, so a mode switch (e.g. an instance moving from database-only to --with-permissions) would
# otherwise leave the "user_app" grant in place - a direct bypass of replication-backend's permission
# checks, since any client CouchDB itself accepts (via that role) could then reach the database directly.
# replication-backend's own startup checks assert this same invariant.
#
# "admin-only" has to be spelled ["_admin"], not []: CouchDB reads an empty members list as "public", so
# empty arrays would open the database to unauthenticated read/write - reachable via /db/couchdb/.
#
# In the database-only case "user_app" is granted as admin AND member.
# Admin lets the app create Mango indices, required for online-only mode.
if [ "$withPermissions" = false ]; then
  echo "Applying document-level security (user_app role as admin and member)..."
  couchdbCurl -X PUT "$DB_LOCAL_URL/app/_security" \
    -d '{"admins": { "names": [], "roles": ["user_app"] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
  couchdbCurl -X PUT "$DB_LOCAL_URL/app-attachments/_security" \
    -d '{"admins": { "names": [], "roles": ["user_app"] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
else
  echo "Resetting document-level security to admin-only (replication-backend enforces access)..."
  couchdbCurl -X PUT "$DB_LOCAL_URL/app/_security" \
    -d '{"admins": { "names": [], "roles": ["_admin"] }, "members": { "names": [], "roles": ["_admin"] } }' >/dev/null
  couchdbCurl -X PUT "$DB_LOCAL_URL/app-attachments/_security" \
    -d '{"admins": { "names": [], "roles": ["_admin"] }, "members": { "names": [], "roles": ["_admin"] } }' >/dev/null

  # couchdb.ini no longer has [jwt_keys], but keys once set via the _config API live in CouchDB's own
  # local.ini and survive the rewrite - remove those too.
  for key in $(couchdbCurl "$DB_LOCAL_URL/_node/_local/_config/jwt_keys" | jq -r 'if type == "object" and (has("error") | not) then keys[] else empty end'); do
    echo "  ~ removing runtime-configured jwt_keys/$key"
    couchdbCurl -X DELETE "$DB_LOCAL_URL/_node/_local/_config/jwt_keys/$(jq -rn --arg k "$key" '$k|@uri')" >/dev/null
  done

  if [ "$(couchdbCurl "$DB_LOCAL_URL/_node/_local/_config/chttpd/require_valid_user_except_for_up")" != '"true"' ]; then
    echo "WARNING: [chttpd] require_valid_user_except_for_up is not active - CouchDB still accepts anonymous requests."
  fi
fi

# Remove the temporary init container so the instance starts from a clean, healthchecked state.
# Data in ./couchdb/data is preserved. Bring the instance up afterwards with `docker compose up -d`.
# (A CouchDB that was already running is left running.)
couchdbInitStop

echo "CouchDB configured for '$org'."
if [ "$withPermissions" = true ] && [ "$DB_REUSED_RUNNING" = true ]; then
  echo "  replication-backend only checks this at startup - restart it to clear earlier CRITICAL warnings:"
  echo "    (cd $path && docker compose restart replication-backend)"
fi
