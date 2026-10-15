#!/bin/bash
usage() {
  cat <<'EOF'
Enable replication-backend (the permission backend) for a database-only instance: switch COMPOSE_PROFILES to
"with-permissions", route the app's /db through replication-backend (DB_ENTRYPOINT_URL), reconfigure CouchDB
for it (create-couchdb.sh --with-permissions: admin-only _security, no JWT auth) and restart the instance.

Usage:
  ./enable-replication-backend.sh <instance> [--skip-restart]

Requires the canonical docker-compose.yml (run update-compose.sh first). Reads everything it needs from the
instance .env, no secrets from setup.env / Bitwarden.

While enabling, users can't sync from the moment CouchDB is reconfigured until the instance is restarted;
with --skip-restart that lasts until you run the printed command.

Re-running it on an instance that already has replication-backend (with-permissions or full-stack*) leaves
COMPOSE_PROFILES alone and only repairs its .env values (DB_ENTRYPOINT_URL, REPLICATION_BACKEND_JWT_SECRET,
AAM_REPLICATION_BACKEND_VERSION), restarting what changed. CouchDB's security config is repaired by
create-couchdb.sh. For all instances with replication-backend:
  ./for-each-instance.sh --only replication-backend ./enable-replication-backend.sh
EOF
  exit "${1:-1}"
}

# CouchDB is reconfigured before .env is switched: if that fails half-way, the instance is locked (admin-only
# _security while the app still talks to CouchDB directly) until a re-run, never open. The reverse order could
# start replication-backend in front of a CouchDB that still grants "user_app" direct access.
#
# REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET is not set here: replication-backend only needs it for the
# permission-check API that aam-backend-service calls, and enable-backend.sh sets it up.

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

##############################
# input
##############################

requireInstance "${1:-}"
envFile="$path/.env"
dbEntrypointUrl="http://${org}-replication-backend:5984"

profile=$(getVar "$envFile" COMPOSE_PROFILES)
enable=false
if profileDeploysReplicationBackend "$profile"; then
  echo "replication-backend is already enabled for '$org' (COMPOSE_PROFILES=$profile), checking its config"
elif [ -z "$profile" ] || [ "$profile" = "database-only" ]; then
  enable=true
  echo "Enabling replication-backend for '$org' (COMPOSE_PROFILES=${profile:-<unset>} -> with-permissions)"
else
  echo "ERROR: unknown COMPOSE_PROFILES '$profile' in $envFile. Abort."
  exit 1
fi

##############################
# preconditions (nothing written yet)
##############################

# An older compose file ignores DB_ENTRYPOINT_URL, so the switch would look fine while /db still goes
# straight to CouchDB - now with admin-only _security, i.e. nobody can sync.
if ! grep -q 'DB_ENTRYPOINT_URL' "$path/docker-compose.yml" 2>/dev/null \
    || ! grep -q '^  replication-backend:' "$path/docker-compose.yml"; then
  echo "ERROR: '$path/docker-compose.yml' has no replication-backend service routed via DB_ENTRYPOINT_URL."
  echo "  Run update-compose.sh for this instance first, then retry."
  exit 1
fi

needsEntrypoint=false
[ "$(getVar "$envFile" DB_ENTRYPOINT_URL)" == "$dbEntrypointUrl" ] || needsEntrypoint=true
needsJwtSecret=false
isPlaceholderValue "$(getVar "$envFile" REPLICATION_BACKEND_JWT_SECRET)" && needsJwtSecret=true
version=""
if isPlaceholderValue "$(getVar "$envFile" AAM_REPLICATION_BACKEND_VERSION)"; then
  if ! version=$(getLatestReplicationBackendVersion); then
    echo "ERROR: could not determine latest replication-backend release version. Abort."
    exit 1
  fi
fi

if [ "$enable" = false ] && [ "$needsEntrypoint" = false ] && [ "$needsJwtSecret" = false ] && [ -z "$version" ]; then
  echo "Nothing to do."
  exit 0
fi

##############################
# CouchDB
##############################

if [ "$enable" = true ]; then
  if ! "$scriptDir/create-couchdb.sh" "$path" --with-permissions ${skipRestartArg[@]+"${skipRestartArg[@]}"}; then
    echo "ERROR: configuring CouchDB for replication-backend failed, .env is unchanged. Fix the cause and re-run."
    exit 1
  fi
fi

##############################
# .env
##############################

abortEnvWrite() {
  echo "ERROR: failed to write $envFile (rollback copy: ${envRollbackCopy:-none}). Abort."
  exit 1
}

saveRollbackCopy "$envFile"
envRollbackCopy="$ROLLBACK_COPY"

if [ "$enable" = true ]; then
  upsertEnv COMPOSE_PROFILES "with-permissions" "$envFile" || abortEnvWrite
fi
if [ "$needsEntrypoint" = true ]; then
  # the app container's /db now has to reach replication-backend instead of CouchDB directly
  upsertEnv DB_ENTRYPOINT_URL "$dbEntrypointUrl" "$envFile" || abortEnvWrite
fi
if [ "$needsJwtSecret" = true ]; then
  upsertEnv REPLICATION_BACKEND_JWT_SECRET "$(generate_password)" "$envFile" || abortEnvWrite
fi
if [ -n "$version" ]; then
  upsertEnv AAM_REPLICATION_BACKEND_VERSION "$version" "$envFile" || abortEnvWrite
fi

##############################
# restart
##############################

# `up -d` recreates the services whose environment changed (app for DB_ENTRYPOINT_URL, replication-backend)
# and starts replication-backend for the new profile.
if ! skipRestartNote "docker compose up -d" "$path"; then
  if ! (cd "$path" && docker compose up -d); then
    echo "ERROR: failed to start '$org' with replication-backend. Check 'docker compose logs' in $path."
    exit 1
  fi
fi

if [ "$enable" = true ]; then
  echo "replication-backend enabled for '$org'."
else
  echo "replication-backend config of '$org' repaired."
fi
