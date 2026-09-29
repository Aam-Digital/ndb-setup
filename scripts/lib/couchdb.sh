#!/bin/bash
# CouchDB init helpers for ndb-setup scripts.
# Source after common.sh. All helpers operate on the instance dir in $path and read credentials from its .env.
#
# CouchDB runs as the single "couchdb" service (container "${INSTANCE_NAME}-database") in every profile, so
# these helpers start just that one service to configure it before the rest of the stack (which may not even
# be selected yet, e.g. replication-backend under a permission profile) is brought up. couchdbInitStop removes
# the container afterward so the instance starts from a clean, healthchecked state once the real
# `docker compose up -d` runs for whichever profile was actually selected. Instance data lives in
# ./couchdb/data and survives the container removal. On a live instance the running container is reused
# and left running instead.

# Print the first path of the CouchDB bind mounts (./couchdb and ./couchdb.ini) not owned by 1000:1000,
# the UID:GID the couchdb containers run as (see ensureCouchdbDataOwnership). Prints nothing if all match.
# Requires: $path.
couchdbOwnershipMismatch() {
  local targets=("$path/couchdb")
  [ -f "$path/couchdb.ini" ] && targets+=("$path/couchdb.ini")
  find "${targets[@]}" \( ! -uid 1000 -o ! -gid 1000 \) -print -quit 2>/dev/null || true
}

# Ensure the CouchDB data directory exists and is owned by the same UID:GID the couchdb containers run
# as (hardcoded "1000:1000" in docker-compose.yml, matching the convention used across this repo's other
# stacks). A mismatch — e.g. the directory got created via sudo, restored from a backup archive, or
# auto-created by Docker as root before this ran — leaves CouchDB unable to write to the bind-mounted
# volume. Left unchecked, that only surfaces indirectly as the 120s readiness timeout in couchdbInitStart.
# Every file is checked, not just the top directory: an old compose file without "user:" ran CouchDB as root,
# whose image entrypoint then chowned the bind mounts (./couchdb/data and couchdb.ini) to its own couchdb user
# (uid 5984) while leaving the unmounted ./couchdb itself untouched - CouchDB then crashes with eacces.
# Requires: $path.
ensureCouchdbDataOwnership() {
  local dataDir="$path/couchdb"
  mkdir -p "$dataDir/data"

  local targets=("$dataDir")
  [ -f "$path/couchdb.ini" ] && targets+=("$path/couchdb.ini")

  local mismatch
  mismatch=$(couchdbOwnershipMismatch)
  if [ -z "$mismatch" ]; then
    return 0
  fi

  echo "  ~ fixing ownership of ${targets[*]} (e.g. $mismatch is $(stat -c '%u:%g' "$mismatch"), needs 1000:1000)"
  if chown -R 1000:1000 "${targets[@]}" 2>/dev/null; then
    return 0
  fi
  if sudo -n chown -R 1000:1000 "${targets[@]}" 2>/dev/null; then
    return 0
  fi

  echo "ERROR: ${targets[*]} not owned by 1000:1000 and could not be fixed automatically" >&2
  echo "  (no permission, and passwordless sudo is unavailable). Run manually:" >&2
  echo "    sudo chown -R 1000:1000 ${targets[*]}" >&2
  return 1
}

# Start CouchDB (or reuse the instance's already-running container) and wait until it answers on /_up.
# Reusing a running container keeps a live instance up: couchdbInitStop then leaves it running.
# Requires: $path. Sets globals: DB_CONTAINER, DB_LOCAL_URL, DB_USER, DB_PASSWORD, DB_REUSED_RUNNING.
couchdbInitStart() {
  DB_LOCAL_URL="http://127.0.0.1:5984"
  DB_USER=$(getVar "$path/.env" COUCHDB_USER)
  DB_PASSWORD=$(getVar "$path/.env" COUCHDB_PASSWORD)
  DB_CONTAINER="$(getVar "$path/.env" INSTANCE_NAME)-database"
  DB_REUSED_RUNNING=false

  if ! (cd "$path" && docker compose config --services 2>/dev/null) | grep -qx couchdb; then
    echo "ERROR: $path/docker-compose.yml has no 'couchdb' service (older schema). Run update-compose.sh first." >&2
    return 1
  fi

  ensureCouchdbDataOwnership || return 1

  # Looked up via the compose service, not the container name: older schemas used a different
  # container_name, and starting a second CouchDB on the same ./couchdb/data would corrupt it.
  local runningId
  runningId=$(cd "$path" && docker compose ps --status running -q couchdb 2>/dev/null)
  if [ -n "$runningId" ]; then
    DB_CONTAINER="$runningId"
    DB_REUSED_RUNNING=true
  else
    # --remove-orphans: a stopped old couchdb-only/couchdb-with-permissions container from a previous
    # schema can still hold the "${INSTANCE_NAME}-database" name - without this flag `up` fails outright
    # on that name conflict instead of creating the couchdb container.
    (cd "$path" && docker compose up -d --remove-orphans couchdb) || return 1
    # target exactly the container just started (exec and the later rm), not whatever holds the name
    DB_CONTAINER=$(cd "$path" && docker compose ps -q couchdb 2>/dev/null)
    if [ -z "$DB_CONTAINER" ]; then
      echo "ERROR: couchdb container of $path not found after starting it. Abort." >&2
      return 1
    fi
  fi

  couchdbWaitUntilUp
}

# Restart the instance's couchdb service (to apply a changed couchdb.ini) and wait until it is up again.
# Requires: couchdbInitStart called first.
couchdbRestart() {
  (cd "$path" && docker compose restart couchdb) || return 1
  couchdbWaitUntilUp
}

# Wait until CouchDB answers on /_up. Requires: couchdbInitStart called first.
couchdbWaitUntilUp() {
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

# Remove the temporary init container (idempotent). Leaves a container running that couchdbInitStart
# found already running.
couchdbInitStop() {
  [ "${DB_REUSED_RUNNING:-false}" = true ] && return 0
  docker rm -f "$DB_CONTAINER" >/dev/null 2>&1 || true
}
