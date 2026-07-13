#!/bin/bash

# Configure CouchDB for an instance: write the JWT signing key into couchdb.ini, start the database,
# create the required databases and (for a directly-exposed database-only instance) apply document-level
# security so only JWTs with the "user_app" role can access the data.
# Idempotent: couchdb.ini is regenerated from the template each run, database creation tolerates existing
# databases, and _security is (re)applied. Reads everything it needs from the instance .env — no secrets.
#
# Usage:
#   ./create-couchdb.sh <instance> [--with-permissions]
#
# <instance>           an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the
#                      instance directory (e.g. "." when run from inside it, or /any/path/to/instance)
# --with-permissions   the replication-backend enforces access, so CouchDB stays internal and the
#                      user_app document security is NOT applied. Omit it for a database-only instance
#                      (CouchDB exposed directly) where the user_app _security must be applied.

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
positionalArgs=()
for arg in "$@"; do
  case "$arg" in
    --with-permissions) withPermissions=true ;;
    *) positionalArgs+=("$arg") ;;
  esac
done
set -- "${positionalArgs[@]+"${positionalArgs[@]}"}"

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

couchDbUser=$(getVar "$path/.env" COUCHDB_USER)
couchDbPassword=$(getVar "$path/.env" COUCHDB_PASSWORD)
kid=$(getVar "$path/.env" KEYCLOAK_JWT_KID)
publicKey=$(getVar "$path/.env" REPLICATION_BACKEND_PUBLIC_KEY)

if [ -z "$couchDbUser" ] || [ -z "$couchDbPassword" ]; then
  echo "ERROR: COUCHDB_USER / COUCHDB_PASSWORD missing in $path/.env. Abort."
  exit 1
fi
if [ -z "$kid" ] || [ -z "$publicKey" ]; then
  echo "ERROR: KEYCLOAK_JWT_KID / REPLICATION_BACKEND_PUBLIC_KEY missing in $path/.env."
  echo "  Run create-keycloak-realm.sh first. Abort."
  exit 1
fi

##############################
# couchdb.ini (JWT signing key)
##############################

# Regenerate from the pristine template each run (the template is static apart from the key placeholders),
# which keeps the substitution idempotent and update-safe even if the key rotated.
cp "$ndbSetupDir/couchdb.ini" "$path/couchdb.ini"
# '|' delimiter avoids clashing with '/' in a base64 key; escape sed-special chars in the value
escapedKey=$(printf '%s' "$publicKey" | sed 's/[\\&|]/\\&/g')
sed -i "s|<KID>|$kid|g" "$path/couchdb.ini"
sed -i "s|<PUBLIC_KEY>|$escapedKey|g" "$path/couchdb.ini"
echo "  ~ wrote JWT signing key into couchdb.ini"

##############################
# start database + create databases
##############################

echo "Starting CouchDB for '$org'..."
couchdbInitStart

# create the required databases (PUT is a no-op / 412 for already-existing databases)
for db in _users app report-calculation notification-webhook app-attachments; do
  couchdbCurl -X PUT "$DB_LOCAL_URL/$db" >/dev/null
  echo "  ensured database '$db'"
done

# For a database-only instance CouchDB is exposed directly, so restrict app / app-attachments to the
# "user_app" role. With the replication-backend (--with-permissions) CouchDB is internal and the backend
# enforces access, so this security is intentionally skipped.
if [ "$withPermissions" = false ]; then
  echo "Applying document-level security (user_app role)..."
  couchdbCurl -X PUT "$DB_LOCAL_URL/app/_security" \
    -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
  couchdbCurl -X PUT "$DB_LOCAL_URL/app-attachments/_security" \
    -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
fi

# Remove the temporary init container so a later profile switch can reuse the -db-entrypoint name.
# Data in ./couchdb/data is preserved. Bring the instance up afterwards with `docker compose up -d`.
couchdbInitStop

echo "CouchDB configured for '$org'."
