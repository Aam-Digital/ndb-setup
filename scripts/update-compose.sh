#!/bin/bash
# Update the docker-compose.yml of every instance to match the canonical
# ndb-setup/docker-compose.yml.
#
# Instances get a *copy* of docker-compose.yml at setup time, so structural
# changes to the canonical file (new service, changed volume, etc.) do not
# propagate automatically. This script previews the diff for each instance,
# asks for confirmation, backs up the old file, copies the new one and
# redeploys the instance ('docker compose up -d').
#
# The wholesale copy drops any instance-local asset volume mounts, so afterwards a
# mount is re-created for every asset present in the instance's assets/ folder (the
# same logic enable-assets-overwrites.sh uses), so updating does not disable them.
#
# It also backfills DB_ENTRYPOINT_URL into any instance's .env whose COMPOSE_PROFILES
# already requires replication-backend (i.e. not "database-only") but predates that
# variable - otherwise the new docker-compose.yml would route /db straight to CouchDB
# on redeploy, silently bypassing replication-backend's permission checks. Same idea for
# API_BACKEND_URL on any full-stack instance, so /api keeps reaching aam-backend-service.
#
# Can be run from any directory.

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

CANONICAL="$baseDirectory/ndb-setup/docker-compose.yml"
ASSUME_YES=0
INSTANCE=""

usage() {
    echo "Usage: $0 [--yes] [instance]"
    echo "  instance  update only this instance (default: all ${PREFIX}* instances)"
    echo "  --yes     skip per-instance confirmation (still skips unchanged)"
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --yes)      ASSUME_YES=1 ;;
        -h|--help)  usage ;;
        -*) echo "Unknown option: $arg"; usage ;;
        *)
            if [ -n "$INSTANCE" ]; then
                echo "Only one instance argument is allowed."
                usage
            fi
            INSTANCE="$arg"
            ;;
    esac
done

if [ ! -f "$CANONICAL" ]; then
    echo "Canonical compose file not found: $CANONICAL"
    exit 1
fi

updated=0
skipped=0

update_instance() {
    local D="$1"
    local target="$D/docker-compose.yml"
    local instance="${D##*/}"

    if [ ! -f "$target" ]; then
        echo "[$instance] no docker-compose.yml, skipping"
        skipped=$((skipped + 1))
        return
    fi

    if diff -q "$target" "$CANONICAL" >/dev/null 2>&1; then
        echo "[$instance] already up to date"
        skipped=$((skipped + 1))
        return
    fi

    echo
    echo "===================================================================="
    echo "[$instance] differs from canonical (- current / + new):"
    echo "--------------------------------------------------------------------"
    diff "$target" "$CANONICAL" || true
    echo "--------------------------------------------------------------------"

    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "Apply this change to [$instance]? [y/N] " reply < /dev/tty
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "[$instance] skipped"; skipped=$((skipped + 1)); return ;;
        esac
    fi

    backupFile "$target"
    # Remember the backup just made so a failed redeploy can roll back config + runtime.
    local previous="$BACKUP_FILE"

    cp "$CANONICAL" "$target"

    # The wholesale copy drops any asset volume mounts, so re-create one for every asset
    # present in the instance's assets/ folder (the filesystem is the source of truth).
    ensureAssetVolumeMountsFromDir "$target" "$D/assets"

    # This canonical version routes /db through DB_ENTRYPOINT_URL when replication-backend
    # enforces access (COMPOSE_PROFILES != database-only). An instance already on such a profile
    # needs this backfilled now: without it, COUCHDB_URL silently falls back to CouchDB directly
    # on redeploy, bypassing every permission check replication-backend exists to enforce.
    local envFile="$D/.env"
    local org composeProfiles
    org=$(getVar "$envFile" INSTANCE_NAME)
    composeProfiles=$(getVar "$envFile" COMPOSE_PROFILES)
    if [ "$composeProfiles" != "database-only" ] && [ -z "$(getVar "$envFile" DB_ENTRYPOINT_URL)" ]; then
        upsertEnv DB_ENTRYPOINT_URL "http://${org}-replication-backend:5984" "$envFile"
    fi

    # Same idea for /api: aam-backend-service is only deployed under the full-stack profiles
    # (unlike replication-backend, not under with-permissions), and previously reached it via
    # nginx-proxy's own VIRTUAL_PATH auto-discovery, bypassing the app container's nginx
    # entirely - a route this canonical version's app service no longer has. Without this
    # backfill /api would silently 502 (API_URL falls back to its always-resolvable default)
    # for every full-stack instance still relying on that old route.
    if { [ "$composeProfiles" = "full-stack" ] || [ "$composeProfiles" = "full-stack-without-sqs" ]; } \
        && [ -z "$(getVar "$envFile" API_BACKEND_URL)" ]; then
        upsertEnv API_BACKEND_URL "http://${org}-aam-backend-service:8080" "$envFile"
    fi

    echo "[$instance] updated"

    echo "[$instance] redeploying..."
    # The merged "couchdb" service inherits container_name "${INSTANCE_NAME}-database" from the
    # couchdb-with-permissions service it replaces, so on that transition `up` has to remove the
    # superseded container before it can create the new one under the same name. Whether Compose
    # does that reliably is version-dependent: on v2.29.7 it converges as a single name-matched
    # recreate and always works, while on v5.5.0 `up` instead fails outright with a Docker-level
    # "container name ... is already in use" conflict, leaving the stack half-converged.
    # --remove-orphans does not prevent it - it decides *what* is obsolete, not *when* it is
    # removed - so free the name here first, addressing the container directly instead of relying
    # on Compose's convergence order. Safe: CouchDB's state lives in the bind-mounted
    # ./couchdb/data, not in the container, so the new couchdb service picks the same data back up.
    local dbContainer="${org}-database"
    local holderService=""
    holderService=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' \
        "$dbContainer" 2>/dev/null) || true
    case "$holderService" in
        couchdb-only|couchdb-with-permissions)
            echo "[$instance] removing superseded $holderService container ($dbContainer)"
            # never abort the run here: this is a best-effort cleanup, and `up` below reports the
            # name conflict clearly enough on its own (with the rollback) if the removal did fail.
            docker rm -f "$dbContainer" >/dev/null || true
            ;;
    esac

    # --remove-orphans: the same service rename leaves the old container behind under its old
    # service label. For database-only, where the old and new container_name differ, no name
    # conflict masks it and `up` would otherwise silently succeed with BOTH CouchDB containers
    # running and bind-mounting the same ./couchdb/data - two processes writing the same files.
    if ! (cd "$D" && docker compose up -d --remove-orphans); then
        echo "[$instance] redeploy failed, rolling back docker-compose.yml and redeploying previous config"
        cp "$previous" "$target"
        (cd "$D" && docker compose up -d --remove-orphans) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed - check 'docker compose ps' and 'docker compose logs' in $D"
        return 1
    fi
    echo "[$instance] redeployed"
    updated=$((updated + 1))
}

forEachInstance update_instance "$INSTANCE"

echo
echo "Done. $updated updated, $skipped skipped."
