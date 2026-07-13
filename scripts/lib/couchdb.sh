#!/bin/bash
# CouchDB init helpers for ndb-setup scripts.
# Source after common.sh. All helpers operate on the instance dir in $path and read credentials from its .env.
#
# The database-only CouchDB runs as the container "${INSTANCE_NAME}-db-entrypoint". That name is reused by
# the replication-backend in the permission profiles, so the init container must be removed (couchdbInitStop)
# before switching profiles. Instance data lives in ./couchdb/data and survives the container removal.

# Start the database-only CouchDB and wait until it answers on /_up.
# Requires: $path. Sets globals: DB_CONTAINER, DB_LOCAL_URL, DB_USER, DB_PASSWORD.
couchdbInitStart() {
  DB_LOCAL_URL="http://127.0.0.1:5984"
  DB_USER=$(getVar "$path/.env" COUCHDB_USER)
  DB_PASSWORD=$(getVar "$path/.env" COUCHDB_PASSWORD)
  DB_CONTAINER="$(getVar "$path/.env" INSTANCE_NAME)-db-entrypoint"

  (cd "$path" && docker compose --profile database-only up -d couchdb-only)

  local status=""
  while [ "$status" != "200" ]; do
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
