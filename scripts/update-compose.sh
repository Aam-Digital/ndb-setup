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
# The wholesale copy would drop any instance-local asset volume mounts, so the target
# file is the canonical one plus a mount for every asset present in the instance's
# assets/ folder (the same logic enable-assets-overwrites.sh uses). The up-to-date check,
# the preview diff and the copy all use that target, so asset mounts (e.g. the
# assets/firebase-config.json written by enable-feature-notification.sh) are neither
# dropped nor reported as a change on every run.
#
# Instances from before the Firebase web config moved to assets/ still mount
# ./firebase-config.json from the instance root; a valid (non-empty) one is carried
# over to assets/ so push notifications keep working after the update.
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

# Print the resolved compose config of instance dir $1 (empty if it does not resolve).
resolvedComposeConfig() {
    (cd "$1" && docker compose config 2>/dev/null) || true
}

# From a resolved compose config on stdin, print "<service> <container_name>" for every active service.
composeContainerNames() {
    awk '
        /^[^ ]/ { inServices = ($0 == "services:"); next }
        inServices && /^  [^ ]/ { svc = $1; sub(/:$/, "", svc); next }
        inServices && $1 == "container_name:" { print svc, $2 }
    '
}

# Free container name $2 ahead of `docker compose up` in instance dir $1: remove the compose-managed
# container holding that name unless it already is the one the current compose config assigns it to
# (same project and service), which `up` converges on its own. Best-effort, never aborts the run.
freeContainerName() {
    local dir="$1" name="$2" instance="${1##*/}"
    local labels holderProject="" holderService="" resolved project owner
    labels=$(docker inspect --type container \
        -f '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' \
        "$name" 2>/dev/null) || return 0   # nothing holds the name
    read -r holderProject holderService <<<"$labels" || true

    resolved=$(resolvedComposeConfig "$dir")
    if [ -z "$resolved" ]; then
        echo "[$instance] WARNING: could not resolve compose config, not touching $name"
        return 0
    fi
    project=$(printf '%s\n' "$resolved" | sed -n 's/^name: *//p')
    owner=$(printf '%s\n' "$resolved" | composeContainerNames | awk -v want="$name" '$2 == want { print $1 }')

    if [ -n "$owner" ] && [ "$holderProject" = "$project" ] && [ "$holderService" = "$owner" ]; then
        return 0
    fi
    if [ -z "$holderProject" ]; then
        echo "[$instance] WARNING: $name is held by a container not managed by compose, not removing it"
        return 0
    fi
    echo "[$instance] removing container $name (held by superseded $holderProject/$holderService)"
    docker rm -f "$name" >/dev/null || true
}

update_instance() {
    local D="$1"
    local target="$D/docker-compose.yml"
    local instance="${D##*/}"

    if [ ! -f "$target" ]; then
        echo "[$instance] no docker-compose.yml, skipping"
        skipped=$((skipped + 1))
        return
    fi

    # Carry over a legacy root-level Firebase web config (see header) - only a valid one, as
    # instances without notifications got the empty template there. Copied after confirmation.
    local legacyFirebase="$D/firebase-config.json" assetsFirebase="$D/assets/firebase-config.json"
    local migrateFirebase=0
    if [ ! -e "$assetsFirebase" ] && [ -f "$legacyFirebase" ] \
        && isValidFirebaseWebConfig "$(cat "$legacyFirebase")"; then
        migrateFirebase=1
    fi

    # The target file: canonical + this instance's asset mounts.
    local expected
    expected=$(mktemp)
    cp "$CANONICAL" "$expected"
    ensureAssetVolumeMountsFromDir "$expected" "$D/assets" >/dev/null
    if [ "$migrateFirebase" -eq 1 ]; then
        ensureAssetVolumeMount "$expected" "firebase-config.json" >/dev/null
    fi

    if diff -q "$target" "$expected" >/dev/null 2>&1; then
        echo "[$instance] already up to date"
        rm -f "$expected"
        skipped=$((skipped + 1))
        return
    fi

    echo
    echo "===================================================================="
    echo "[$instance] differs from canonical + its asset mounts (- current / + new):"
    echo "--------------------------------------------------------------------"
    diff "$target" "$expected" || true
    echo "--------------------------------------------------------------------"
    if [ "$migrateFirebase" -eq 1 ]; then
        echo "[$instance] will copy ./firebase-config.json to ./assets/firebase-config.json"
    fi

    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "Apply this change to [$instance]? [y/N] " reply < /dev/tty
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "[$instance] skipped"; rm -f "$expected"; skipped=$((skipped + 1)); return ;;
        esac
    fi

    backupFile "$target"
    # Remember the backup just made so a failed redeploy can roll back config + runtime.
    local previous="$BACKUP_FILE"

    if [ "$migrateFirebase" -eq 1 ]; then
        mkdir -p "$D/assets"
        cp "$legacyFirebase" "$assetsFirebase"
        chmod 644 "$assetsFirebase"
        echo "[$instance] copied firebase-config.json to assets/"
    fi

    cp "$expected" "$target"
    rm -f "$expected"

    # This canonical version routes /db through DB_ENTRYPOINT_URL when replication-backend
    # enforces access (COMPOSE_PROFILES is with-permissions, full-stack or full-stack-without-sqs -
    # the profiles that actually deploy replication-backend; unset/empty behaves like database-only,
    # i.e. no profile active). An instance already on such a profile needs this backfilled now:
    # without it, COUCHDB_URL silently falls back to CouchDB directly on redeploy, bypassing every
    # permission check replication-backend exists to enforce.
    local envFile="$D/.env"
    local org composeProfiles
    org=$(getVar "$envFile" INSTANCE_NAME)
    composeProfiles=$(getVar "$envFile" COMPOSE_PROFILES)

    backupFile "$envFile"
    # Remember the .env backup (if any) so a failed redeploy can roll it back alongside docker-compose.yml.
    local previousEnv="$BACKUP_FILE"

    if { [ "$composeProfiles" = "with-permissions" ] || [ "$composeProfiles" = "full-stack" ] || [ "$composeProfiles" = "full-stack-without-sqs" ]; } \
        && [ -z "$(getVar "$envFile" DB_ENTRYPOINT_URL)" ]; then
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
    # The name is taken from the resolved config (Compose strips quotes/CRs from .env that getVar keeps),
    # and any holder other than this project's couchdb service is removed - not just known old service
    # names - so leftovers of a previous partial run or a different project name are cleared as well.
    local dbContainer
    dbContainer=$(resolvedComposeConfig "$D" | composeContainerNames | awk '$1 == "couchdb" { print $2 }')
    dbContainer="${dbContainer:-${org}-database}"
    freeContainerName "$D" "$dbContainer"

    # --remove-orphans: the same service rename leaves the old container behind under its old
    # service label. For database-only, where the old and new container_name differ, no name
    # conflict masks it and `up` would otherwise silently succeed with BOTH CouchDB containers
    # running and bind-mounting the same ./couchdb/data - two processes writing the same files.
    if ! (cd "$D" && docker compose up -d --remove-orphans); then
        echo "[$instance] redeploy failed, rolling back docker-compose.yml and .env and redeploying previous config"
        # The rollback below removes the new database container, so capture why it failed first.
        if docker inspect --type container "$dbContainer" >/dev/null 2>&1; then
            echo "[$instance] --- $dbContainer state / health checks:"
            docker inspect -f '{{.State.Status}} (restarts: {{.RestartCount}}, exit code: {{.State.ExitCode}}){{if .State.Health}}{{range .State.Health.Log}}{{"\n"}}  {{.Start}} exit={{.ExitCode}} {{.Output}}{{end}}{{end}}' \
                "$dbContainer" 2>&1 || true
            echo "[$instance] --- $dbContainer logs (last 40 lines):"
            docker logs --tail 40 "$dbContainer" 2>&1 || true
            echo "[$instance] ---"
        fi
        cp "$previous" "$target"
        if [ -n "$previousEnv" ]; then
            cp "$previousEnv" "$envFile"
        fi
        # The failed `up` may already have created the new couchdb container under the name the
        # restored couchdb-with-permissions service needs, so free it in this direction too.
        freeContainerName "$D" "$dbContainer"
        (cd "$D" && docker compose up -d --remove-orphans) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed - check 'docker compose ps' and 'docker compose logs' in $D"
        return 1
    fi
    echo "[$instance] redeployed"
    updated=$((updated + 1))
}

forEachInstance update_instance "$INSTANCE"

echo
echo "Done. $updated updated, $skipped skipped."
