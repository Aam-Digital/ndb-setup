#!/bin/bash
usage() {
  cat <<'EOF'
Update the pinned image version of a service of an instance (APP_VERSION, AAM_REPLICATION_BACKEND_VERSION or
AAM_BACKEND_SERVICE_VERSION in .env) from old_version to new_version, then pull and redeploy. An instance that
is not on old_version is skipped.

Usage:
  ./update-version.sh <instance> <service> <old_version> <new_version> [--skip-restart]

  service         ndb-core | replication-backend | aam-services
  --skip-restart  only update .env; the instance picks the version up on its next
                  'docker compose pull && docker compose up -d'

For every service, crossing into a new major version is only allowed one major at a time and from the
last release of the current one, deployed and started at least once: a major generally drops the
migrations of the major before it, so skipping ahead silently loses whatever they would have carried
over. The refusal names the release to go via. The instance has to be running for a major update, as
its container is the only evidence the old version really started; updates within a major don't check
that. Pin the version in .env, since a floating tag can't be checked either.

After raising aam-services, run ./enable-backend.sh for the instance: the Keycloak clients are imported from
the definitions of the release it runs, and a release needing a new permission only gets it that way.

Example: ./update-version.sh acme ndb-core 3.5.0 3.6.0
For all instances: ./for-each-instance.sh ./update-version.sh <service> <old_version> <new_version>
EOF
  exit "${1:-1}"
}

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

positional=()
for arg in "$@"; do
    case "$arg" in
        -*) echo "Unknown option: $arg"; usage ;;
        *)  positional+=("$arg") ;;
    esac
done

if [ "${#positional[@]}" -ne 4 ]; then
    usage
fi

INSTANCE="${positional[0]}"
SERVICE="${positional[1]}"
OLD_VERSION="${positional[2]}"
NEW_VERSION="${positional[3]}"

# The .env key this service's version lives under. Where its releases are tagged and what its container
# is called come from componentReleaseSource, which update-compose.sh reads too.
case "$SERVICE" in
    ndb-core)             VAR="APP_VERSION" ;;
    replication-backend)  VAR="AAM_REPLICATION_BACKEND_VERSION" ;;
    aam-services)         VAR="AAM_BACKEND_SERVICE_VERSION" ;;
    *) echo "Invalid service name. Use ndb-core, replication-backend, aam-services."; exit 1 ;;
esac
IFS='|' read -r REPO TAG_PREFIX CONTAINER_SUFFIX < <(componentReleaseSource "$SERVICE")

# A major release generally drops what the majors before it migrated away from. aam-services 2.0.0 is
# the case in hand: it deleted the one-shot migrations that copied push device registrations, auth
# redirect bindings and change-detection cursors out of PostgreSQL. An instance that crosses the
# boundary without having run the last release before it never runs them, and that data doesn't come
# back - Firebase mints push tokens on the client, and ndb-core only re-registers when a user toggles
# push in settings.
#
# Rather than naming the versions of one such transition, this enforces the general rule for every
# service: cross one major at a time, and only from its last release, actually deployed. Nothing here
# knows anything about PostgreSQL, so it keeps holding for the next major of any component.
# Args: instance dir, instance label
checkMajorStep() {
    local D="$1" instance="$2" oldMajor newMajor latestOfOld runningVersion
    # No major to compare (unset, or a floating tag like `latest`): nothing to enforce, as before.
    oldMajor=$(versionMajor "$OLD_VERSION") || return 0
    newMajor=$(versionMajor "$NEW_VERSION") || return 0
    [ "$newMajor" -gt "$oldMajor" ] || return 0   # same major, or a downgrade: not this check's business

    if [ "$newMajor" -gt "$((oldMajor + 1))" ]; then
        echo "[$instance] ERROR: $SERVICE $OLD_VERSION -> $NEW_VERSION skips major $((oldMajor + 1)). Each major drops"
        echo "[$instance]        the migrations of the one before it, so go up one major at a time."
        return 1
    fi

    if ! latestOfOld=$(getLatestVersionOfMajor "$REPO" "$TAG_PREFIX" "$oldMajor"); then
        echo "[$instance] ERROR: could not determine the latest ${oldMajor}.x release of $SERVICE (no network, or no"
        echo "[$instance]        tags matched), so it is not verifiable that $OLD_VERSION is the last one before"
        echo "[$instance]        $NEW_VERSION. Not changing anything."
        return 1
    fi
    if [ "$(_normalizeVersion "$OLD_VERSION")" != "$latestOfOld" ]; then
        echo "[$instance] ERROR: $SERVICE $OLD_VERSION -> $NEW_VERSION crosses into major $newMajor, but $latestOfOld is the"
        echo "[$instance]        last ${oldMajor}.x release. Whatever it migrates is gone from ${newMajor}.x, so go via it first:"
        echo "[$instance]          ./update-version.sh $instance $SERVICE $OLD_VERSION $latestOfOld"
        echo "[$instance]        and let it start up once, then update to $NEW_VERSION."
        return 1
    fi

    # A migration runs at startup, so the pin in .env is not enough: $OLD_VERSION has to have been
    # deployed. A container whose version can't be established is no evidence that it was, so it is
    # refused rather than passed - this only guards a major upgrade, which is rare and deliberate enough
    # to require the instance to be up, and a warning would scroll past unnoticed in a
    # for-each-instance.sh run.
    if ! runningVersion=$(runningContainerVersion "${org}${CONTAINER_SUFFIX}"); then
        echo "[$instance] ERROR: could not establish which version ${org}${CONTAINER_SUFFIX} is running, so it is not"
        echo "[$instance]        verifiable that $SERVICE $OLD_VERSION started and ran its migrations - which ${newMajor}.x"
        echo "[$instance]        no longer carries. Bring the instance up on $OLD_VERSION ('docker compose up -d' in"
        echo "[$instance]        $D), then re-run. Not changing anything."
        return 1
    fi
    if [ "$runningVersion" != "$(_normalizeVersion "$OLD_VERSION")" ]; then
        echo "[$instance] ERROR: .env pins $SERVICE $OLD_VERSION, but the running container is on $runningVersion."
        echo "[$instance]        $OLD_VERSION has to have started once for its migrations to have run, so deploy it"
        echo "[$instance]        before going to $NEW_VERSION: 'docker compose pull && docker compose up -d' in $D."
        return 1
    fi
}

update_instance() {
    local D="$1"
    local instance="${D##*/}"
    local envFile="$D/.env"

    if [ ! -f "$envFile" ]; then
        echo "[$instance] no .env, skipping"
        return 0
    fi

    local current
    current=$(getVar "$envFile" "$VAR")

    if [ "$current" != "$OLD_VERSION" ]; then
        echo "[$instance] $VAR=${current:-<unset>} (not $OLD_VERSION), skipping"
        return 0
    fi

    if ! checkMajorStep "$D" "$instance"; then
        return 1
    fi

    echo
    echo "[$instance] $VAR: $OLD_VERSION -> $NEW_VERSION"

    setEnv "$VAR" "$NEW_VERSION" "$envFile"

    if [ "$skipRestart" = true ]; then
        echo "[$instance] updated .env (not redeployed)"
        return 0
    fi

    echo "[$instance] redeploying..."
    if ! (cd "$D" && docker compose pull && docker compose up -d); then
        echo "[$instance] redeploy failed, rolling back to $VAR=$OLD_VERSION"
        setEnv "$VAR" "$OLD_VERSION" "$envFile"
        # Restore the previous runtime too, not just the config on disk.
        (cd "$D" && docker compose up -d) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed"
        return 1
    fi
    echo "[$instance] redeployed"
}

requireInstance "$INSTANCE"
update_instance "$path"
