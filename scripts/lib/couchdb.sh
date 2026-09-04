#!/bin/bash
# CouchDB init helpers for ndb-setup scripts.
# Source after common.sh. All helpers operate on the instance dir in $path and read credentials from its .env.
#
# The database-only CouchDB runs as the container "${INSTANCE_NAME}-db-entrypoint". That name is reused by
# the replication-backend in the permission profiles, so the init container must be removed (couchdbInitStop)
# before switching profiles. Instance data lives in ./couchdb/data and survives the container removal.

# Ensure the CouchDB data directory exists and is owned by the same UID:GID the couchdb containers run
# as (hardcoded "1000:1000" in docker-compose.yml, matching the convention used across this repo's other
# stacks). A mismatch — e.g. the directory got created via sudo, restored from a backup archive, or
# auto-created by Docker as root before this ran — leaves CouchDB unable to write to the bind-mounted
# volume. Left unchecked, that only surfaces indirectly as the 120s readiness timeout in couchdbInitStart.
# Requires: $path.
ensureCouchdbDataOwnership() {
  local dataDir="$path/couchdb"
  mkdir -p "$dataDir/data"

  local owner
  owner=$(stat -c '%u:%g' "$dataDir")
  if [ "$owner" = "1000:1000" ]; then
    return 0
  fi

  echo "  ~ fixing ownership of $dataDir (currently $owner, needs 1000:1000)"
  if chown -R 1000:1000 "$dataDir" 2>/dev/null; then
    return 0
  fi
  if sudo -n chown -R 1000:1000 "$dataDir" 2>/dev/null; then
    return 0
  fi

  echo "ERROR: $dataDir is not owned by 1000:1000 and could not be fixed automatically" >&2
  echo "  (no permission, and passwordless sudo is unavailable). Run manually:" >&2
  echo "    sudo chown -R 1000:1000 $dataDir" >&2
  return 1
}

# Start the database-only CouchDB and wait until it answers on /_up.
# Requires: $path. Sets globals: DB_CONTAINER, DB_LOCAL_URL, DB_USER, DB_PASSWORD.
couchdbInitStart() {
  DB_LOCAL_URL="http://127.0.0.1:5984"
  DB_USER=$(getVar "$path/.env" COUCHDB_USER)
  DB_PASSWORD=$(getVar "$path/.env" COUCHDB_PASSWORD)
  DB_CONTAINER="$(getVar "$path/.env" INSTANCE_NAME)-db-entrypoint"

  ensureCouchdbDataOwnership || return 1

  (cd "$path" && docker compose --profile database-only up -d couchdb-only)

  local status=""
  local attempts=0
  local maxAttempts=30
  while [ "$status" != "200" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt "$maxAttempts" ]; then
      echo "ERROR: CouchDB did not become ready after $((maxAttempts * 4))s. Abort." >&2
      return 1
    fi
    sleep 4
    echo "Waiting for DB to be ready"
    status=$(docker exec "$DB_CONTAINER" curl -s -o /dev/null -w "%{http_code}" -u "$DB_USER:$DB_PASSWORD" "$DB_LOCAL_URL/_up")
  done
}

# Run an authenticated curl against the init container. Extra args are passed to curl.
# Requires: couchdbInitStart called first.
couchdbCurl() {
  docker exec "$DB_CONTAINER" curl -s -u "$DB_USER:$DB_PASSWORD" "$@"
}

# Remove the temporary init container (idempotent).
couchdbInitStop() {
  docker rm -f "$DB_CONTAINER" >/dev/null 2>&1 || true
}
