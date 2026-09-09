#!/bin/bash
# CouchDB init helpers for ndb-setup scripts.
# Source after common.sh. All helpers operate on the instance dir in $path and read credentials from its .env.
#
# CouchDB runs as the single "couchdb" service (container "${INSTANCE_NAME}-database") in every profile, so
# these helpers start just that one service to configure it before the rest of the stack (which may not even
# be selected yet, e.g. replication-backend under a permission profile) is brought up. couchdbInitStop removes
# the container afterward so the instance starts from a clean, healthchecked state once the real
# `docker compose up -d` runs for whichever profile was actually selected. Instance data lives in
# ./couchdb/data and survives the container removal.

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
  DB_CONTAINER="$(getVar "$path/.env" INSTANCE_NAME)-database"

  ensureCouchdbDataOwnership || return 1

  # --remove-orphans: on an instance whose docker-compose.yml still predates the merged "couchdb"
  # service (i.e. update-compose.sh hasn't run here yet), an old couchdb-only/couchdb-with-permissions
  # container from the previous schema can already hold the "${INSTANCE_NAME}-database" name - without
  # this flag `up` fails outright on that name conflict instead of creating the couchdb container.
  (cd "$path" && docker compose up -d --remove-orphans couchdb)

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
