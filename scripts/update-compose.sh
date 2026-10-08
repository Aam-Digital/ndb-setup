#!/bin/bash
usage() {
  cat <<'EOF'
Update the docker-compose.yml of an instance to the canonical ndb-setup/docker-compose.yml: show the diff, ask
for confirmation, save a rollback copy, copy the new file and redeploy ('docker compose pull' and 'up -d').

Usage:
  ./update-compose.sh <instance> [--yes] [--skip-restart]

  --yes           don't ask for confirmation (an unchanged instance is still skipped)
  --skip-restart  only update docker-compose.yml, don't pull or redeploy

The instance's asset volume mounts (assets/, e.g. firebase-config.json) are kept. It also fills in .env
values the new file relies on (DB_ENTRYPOINT_URL with replication-backend, API_BACKEND_URL with the backend),
so /db and /api keep going through those services.

The current canonical file no longer deploys the PostgreSQL and RabbitMQ containers of
aam-backend-service; the redeploy removes them. A full-stack instance is therefore only updated once
AAM_BACKEND_SERVICE_VERSION is pinned (not `latest`) and on a major that no longer needs them -
otherwise the update is refused and the instance left untouched, so update the backend first:
  ./for-each-instance.sh --only backend ./update-version.sh aam-services <old> <new>
update-version.sh enforces how that update may cross a major boundary (one major at a time, from its
last release), so follow what it tells you rather than jumping straight to the newest release.
Their data directories (storage/rabbitmq, storage/aam-backend-service/postgresql-data) are left on disk
and only reported, so a rollback still finds them; delete them once the instance has settled.
Afterwards ./for-each-instance.sh --only backend ./enable-backend.sh drops the config keys that go with
them from application.env.

For all instances: ./for-each-instance.sh ./update-compose.sh [--yes]
EOF
  exit "${1:-1}"
}

# Instances get a *copy* of docker-compose.yml at setup time, so changes to the canonical file don't propagate
# by themselves. The target file is the canonical one plus a mount for every asset in the instance's assets/
# folder (the same logic update-assets.sh uses); the up-to-date check, the preview diff and the copy all use
# that target, so asset mounts are neither dropped nor reported as a change on every run.
#
# Instances from before the Firebase web config moved to assets/ still mount ./firebase-config.json from the
# instance root; a valid (non-empty) one is carried over to assets/ so push notifications keep working.
#
# Without the backfilled DB_ENTRYPOINT_URL, the new docker-compose.yml would route /db straight to CouchDB on
# redeploy, silently bypassing replication-backend's permission checks. Same for API_BACKEND_URL and /api.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/couchdb.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

CANONICAL="$ndbSetupDir/docker-compose.yml"
ASSUME_YES=0
INSTANCE=""

for arg in "$@"; do
    case "$arg" in
        --yes)      ASSUME_YES=1 ;;
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

# Report the bind-mounted data of aam-backend-service's removed PostgreSQL and RabbitMQ containers, which
# `up --remove-orphans` takes the containers away from but leaves on disk. Deliberately only reported, never
# deleted: a rollback to the previous docker-compose.yml brings those containers back and needs this data,
# and dropping a database directory is not something this script should do unattended.
# Args: instance dir
reportLeftoverBackendStorage() {
    local dir="$1" instance="${1##*/}" leftovers=() d
    for d in storage/aam-backend-service/postgresql-data storage/rabbitmq; do
        [ -d "$dir/$d" ] && leftovers+=("$d")
    done
    [ "${#leftovers[@]}" -gt 0 ] || return 0
    echo "[$instance] note: the removed PostgreSQL/RabbitMQ containers left their data behind:"
    for d in "${leftovers[@]}"; do
        echo "[$instance]         $dir/$d"
    done
    echo "[$instance]       Nothing reads it any more. Delete it once the instance has settled on the new setup."
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
        return 0
    fi

    # The canonical file no longer deploys aam-backend-service's PostgreSQL and RabbitMQ containers, so the
    # redeploy below takes them away (as orphans). A backend that still stores its state in PostgreSQL would
    # come back up crash-looping on an unreachable datasource - and `docker compose up -d` doesn't wait for
    # the backend to be healthy, so the redeploy would still report success. Refuse before anything is
    # written, so the instance keeps running on its current config until it has been updated.
    local backendVersion backendMajor
    backendVersion=$(getVar "$D/.env" AAM_BACKEND_SERVICE_VERSION)
    if profileDeploysBackend "$(getVar "$D/.env" COMPOSE_PROFILES)"; then
        # Unpinned (empty, or the floating `latest` tag) says nothing about what the instance runs, so
        # ask the running container itself.
        if ! backendMajor=$(versionMajor "$backendVersion"); then
            local repo prefix suffix nextMajorLatest lookup
            IFS='|' read -r repo prefix suffix < <(componentReleaseSource aam-services)
            if ! backendVersion=$(runningContainerVersion "$(getVar "$D/.env" INSTANCE_NAME)$suffix"); then
                echo "[$instance] ERROR: AAM_BACKEND_SERVICE_VERSION is not pinned and the running backend's version could"
                echo "[$instance]        not be read, so it is not verifiable that it can run on this docker-compose.yml"
                echo "[$instance]        (which needs ${COMPOSE_REQUIRES_BACKEND_MAJOR}.x). Pin the version it runs in .env, then re-run."
                echo "[$instance]        Not changing anything."
                return 1
            fi
            backendMajor=$(versionMajor "$backendVersion")
            # The redeploy pulls, and an unpinned backend follows `latest` wherever it has moved. So what
            # matters is not only the major it runs now but whether a newer one exists to be pulled into -
            # which would skip that major's one-shot migrations. Asked generically, so this keeps holding
            # for the majors after this one.
            # `&& ... ||` because the lookup returns 1 for "no such major" (the expected case), which would end the script under set -e
            nextMajorLatest=$(getLatestVersionOfMajor "$repo" "$prefix" "$((backendMajor + 1))") && lookup=0 || lookup=$?
            if [ "$lookup" -eq 0 ]; then
                echo "[$instance] ERROR: the backend is unpinned and running $backendVersion, but $nextMajorLatest has been released."
                echo "[$instance]        The redeploy pulls, so it would cross into major $((backendMajor + 1)) here and skip the one-shot"
                echo "[$instance]        migrations in between. Pin AAM_BACKEND_SERVICE_VERSION in .env (update-version.sh"
                echo "[$instance]        then takes it up one major at a time). Not changing anything."
                return 1
            elif [ "$lookup" -ne 1 ]; then
                echo "[$instance] ERROR: the backend is unpinned and it could not be checked whether a major newer than"
                echo "[$instance]        $backendMajor has been released, which the redeploy's pull would cross into."
                echo "[$instance]        Pin AAM_BACKEND_SERVICE_VERSION in .env, then re-run. Not changing anything."
                return 1
            fi
        fi
        if [ "$backendMajor" -lt "$COMPOSE_REQUIRES_BACKEND_MAJOR" ]; then
            echo "[$instance] ERROR: AAM_BACKEND_SERVICE_VERSION=$backendVersion is a ${backendMajor}.x release, but this"
            echo "[$instance]        docker-compose.yml needs ${COMPOSE_REQUIRES_BACKEND_MAJOR}.x (${backendMajor}.x still runs on containers it no longer"
            echo "[$instance]        deploys). Update the backend first:"
            echo "[$instance]          ./update-version.sh $instance aam-services $backendVersion <${COMPOSE_REQUIRES_BACKEND_MAJOR}.x-version>"
            echo "[$instance]        Not changing anything."
            return 1
        fi
    fi

    # Carry over a legacy root-level Firebase web config (see header) - only a valid one, as
    # instances without notifications got the empty template there. Copied after confirmation.
    # A directory at assets/firebase-config.json counts as missing: Docker creates one when the
    # mounted file does not exist (writeFirebaseWebConfig replaces it).
    local legacyFirebase="$D/firebase-config.json" assetsFirebase="$D/assets/firebase-config.json"
    local migrateFirebase=0
    if [ ! -f "$assetsFirebase" ] && [ -f "$legacyFirebase" ]; then
        # Without jq every config would look invalid and its mount be dropped silently.
        if ! command -v jq >/dev/null 2>&1; then
            echo "[$instance] ERROR: jq is required to check ./firebase-config.json before its mount is dropped, skipping"
            return 0
        fi
        if isValidFirebaseWebConfig "$(cat "$legacyFirebase")"; then
            migrateFirebase=1
        else
            echo "[$instance] note: ./firebase-config.json is not a valid Firebase web config (e.g. the empty template),"
            echo "[$instance]       so its legacy mount is dropped without carrying it over to assets/"
        fi
    elif [ -d "$assetsFirebase" ]; then
        echo "[$instance] WARNING: assets/firebase-config.json is a directory (Docker creates one when a mounted file is"
        echo "[$instance]          missing), so push notifications cannot register. Re-run enable-notifications.sh."
    fi

    # The target file: canonical + this instance's asset mounts.
    local expected
    expected=$(mktemp)
    cp "$CANONICAL" "$expected"
    ensureAssetVolumeMountsFromDir "$expected" "$D/assets" >/dev/null
    if [ "$migrateFirebase" -eq 1 ]; then
        ensureAssetVolumeMount "$expected" "firebase-config.json" >/dev/null
    fi

    local composeChanged=1
    if diff -q "$target" "$expected" >/dev/null 2>&1; then
        composeChanged=0
        if [ "$migrateFirebase" -eq 0 ]; then
            rm -f "$expected"
            echo "[$instance] already up to date"
            return 0
        fi
        # docker-compose.yml may already mount assets/firebase-config.json (e.g. an earlier run was
        # interrupted before the copy) while the file itself is still missing - complete that copy.
        echo "[$instance] docker-compose.yml up to date, but assets/firebase-config.json is missing"
    else
        echo
        echo "===================================================================="
        echo "[$instance] differs from canonical + its asset mounts (- current / + new):"
        echo "--------------------------------------------------------------------"
        diff "$target" "$expected" || true
        echo "--------------------------------------------------------------------"

        # Instances created from a compose file without "user:" on CouchDB ran it as root, so the image
        # entrypoint chowned ./couchdb/data to its own couchdb user (uid 5984). The couchdb service runs as
        # 1000:1000 and crashes on eacces with that data, so the redeploy below would fail and roll back.
        # Only point it out (ownership is left to the operator), before anything is changed.
        local ownershipMismatch
        ownershipMismatch=$(path="$D"; couchdbOwnershipMismatch)
        if [ -n "$ownershipMismatch" ]; then
            echo "[$instance] WARNING: $ownershipMismatch is owned by $(stat -c '%u:%g' "$ownershipMismatch"), but CouchDB runs as 1000:1000"
            echo "[$instance]          and will fail to start (the redeploy then rolls back). Fix it first:"
            echo "[$instance]            sudo chown -R 1000:1000 $D/couchdb $D/couchdb.ini"
        fi
    fi
    if [ "$migrateFirebase" -eq 1 ]; then
        echo "[$instance] will copy ./firebase-config.json to ./assets/firebase-config.json"
    fi

    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "Apply this change to [$instance]? [y/N] " reply < /dev/tty
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "[$instance] skipped"; rm -f "$expected"; return 0 ;;
        esac
    fi

    if [ "$migrateFirebase" -eq 1 ]; then
        if ! writeFirebaseWebConfig "$assetsFirebase" "$(cat "$legacyFirebase")"; then
            echo "[$instance] ERROR: could not copy firebase-config.json to assets/, nothing changed"
            rm -f "$expected"
            return 1
        fi
        echo "[$instance] copied firebase-config.json to assets/"
    fi

    if [ "$composeChanged" -eq 0 ]; then
        rm -f "$expected"
        echo "[$instance] run 'docker compose up -d' in $D if the app container predates the mount"
        return 0
    fi

    saveRollbackCopy "$target"
    # Remember the rollback copy just made so a failed redeploy can roll back config + runtime.
    local previous="$ROLLBACK_COPY"

    cp "$expected" "$target"
    rm -f "$expected"

    # This canonical version routes /db through DB_ENTRYPOINT_URL when replication-backend
    # enforces access (see profileDeploysReplicationBackend). An instance already on such a
    # profile needs this backfilled now:
    # without it, COUCHDB_URL silently falls back to CouchDB directly on redeploy, bypassing every
    # permission check replication-backend exists to enforce.
    local envFile="$D/.env"
    local org composeProfiles
    org=$(getVar "$envFile" INSTANCE_NAME)
    composeProfiles=$(getVar "$envFile" COMPOSE_PROFILES)

    saveRollbackCopy "$envFile"
    # Remember the .env rollback copy (if any) so a failed redeploy can roll it back alongside docker-compose.yml.
    local previousEnv="$ROLLBACK_COPY"

    if profileDeploysReplicationBackend "$composeProfiles" \
        && [ -z "$(getVar "$envFile" DB_ENTRYPOINT_URL)" ]; then
        upsertEnv DB_ENTRYPOINT_URL "http://${org}-replication-backend:5984" "$envFile"
    fi

    # Same idea for /api: aam-backend-service is only deployed under the full-stack profiles
    # (unlike replication-backend, not under with-permissions), and previously reached it via
    # nginx-proxy's own VIRTUAL_PATH auto-discovery, bypassing the app container's nginx
    # entirely - a route this canonical version's app service no longer has. Without this
    # backfill /api would silently 502 (API_URL falls back to its always-resolvable default)
    # for every full-stack instance still relying on that old route.
    if profileDeploysBackend "$composeProfiles" \
        && [ -z "$(getVar "$envFile" API_BACKEND_URL)" ]; then
        upsertEnv API_BACKEND_URL "http://${org}-aam-backend-service:8080" "$envFile"
    fi

    echo "[$instance] updated"

    if skipRestartNote "docker compose pull && docker compose up -d --remove-orphans" "$D"; then
        echo "[$instance] docker-compose.yml updated (not redeployed)"
        return 0
    fi

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

    # Pull first, before freeing the container name, so the images the new config
    # references are in place (keeping the downtime short) and a pull failure rolls back
    # while the old containers are still running.
    #
    # --remove-orphans: the same service rename leaves the old container behind under its old
    # service label. For database-only, where the old and new container_name differ, no name
    # conflict masks it and `up` would otherwise silently succeed with BOTH CouchDB containers
    # running and bind-mounting the same ./couchdb/data - two processes writing the same files.
    if ! (cd "$D" && docker compose pull) \
        || ! freeContainerName "$D" "$dbContainer" \
        || ! (cd "$D" && docker compose up -d --remove-orphans); then
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
    reportLeftoverBackendStorage "$D"
}

[ -n "$INSTANCE" ] || usage
requireInstance "$INSTANCE"
update_instance "$path"
