#!/bin/bash

# Configure CouchDB for an instance: write couchdb.ini (with or without the JWT signing key, depending on
# mode - see below), start the database, create the required databases and apply the document-level
# _security appropriate for the mode: "user_app" as database admin and member for a directly-exposed
# database-only instance, or admin-only (resetting any previously-applied "user_app" grant) when
# replication-backend fronts it.
# Idempotent: couchdb.ini is regenerated from the template each run, database creation tolerates existing
# databases, and _security is (re)applied. Reads everything it needs from the instance .env — no secrets.
#
# Usage:
#   ./create-couchdb.sh <instance> [--with-permissions]
#
# <instance>           an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the
#                      instance directory (e.g. "." when run from inside it, or /any/path/to/instance)
# --with-permissions   the replication-backend enforces access, so CouchDB stays internal and _security
#                      is reset to admin-only instead of granting "user_app". Omit it for a database-only
#                      instance (CouchDB exposed directly) where the user_app _security must be applied.

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
couchdbInitStart || exit 1

# create the required databases (201 = created, 412 = already exists; anything else is a real failure)
for db in _users app report-calculation notification-webhook app-attachments; do
  status=$(couchdbCurl -X PUT "$DB_LOCAL_URL/$db" -o /dev/null -w "%{http_code}")
  if [ "$status" != "201" ] && [ "$status" != "412" ]; then
    echo "ERROR: failed to create database '$db' (HTTP $status). Abort."
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
# replication-backend's own startup checks assert this same invariant and refuse to start if it is wrong.
#
# In the database-only case "user_app" is granted twice over, as database admin AND as member, because
# the two do different jobs. As a member it is what keeps the database private: CouchDB treats an empty
# members list as "any user can read and write regular documents"
# (docs.couchdb.org/en/stable/api/database/security.html), so removing it would widen access rather than
# narrow it. As an admin it is what lets the app create Mango indices - ndb-core calls createIndex on the
# remote database whenever a list is sorted, and an index is a design document, which CouchDB only lets a
# database admin write ("Admin permission required" for a mere member). The admin grant is broader than
# index creation alone - a database admin can also rewrite _security itself - which is acceptable only
# because "user_app" already reaches all of this database's data in this mode. Keep this body identical to
# configureDatabaseSecurity in aam-cloud-infrastructure's couchdb-setup.ts, which secures cluster
# instances the same way.
if [ "$withPermissions" = false ]; then
  echo "Applying document-level security (user_app role as admin and member)..."
  couchdbCurl -X PUT "$DB_LOCAL_URL/app/_security" \
    -d '{"admins": { "names": [], "roles": ["user_app"] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
  couchdbCurl -X PUT "$DB_LOCAL_URL/app-attachments/_security" \
    -d '{"admins": { "names": [], "roles": ["user_app"] }, "members": { "names": [], "roles": ["user_app"] } }' >/dev/null
else
  echo "Resetting document-level security to admin-only (replication-backend enforces access)..."
  couchdbCurl -X PUT "$DB_LOCAL_URL/app/_security" \
    -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": [] } }' >/dev/null
  couchdbCurl -X PUT "$DB_LOCAL_URL/app-attachments/_security" \
    -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": [] } }' >/dev/null
fi

# Remove the temporary init container so a later profile switch can reuse the -db-entrypoint name.
# Data in ./couchdb/data is preserved. Bring the instance up afterwards with `docker compose up -d`.
couchdbInitStop

echo "CouchDB configured for '$org'."
