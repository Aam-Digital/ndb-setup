#!/bin/bash
# Update the pinned image version for a service across instances.
#
# Each instance pins its service versions in .env (APP_VERSION,
# AAM_REPLICATION_BACKEND_VERSION, AAM_BACKEND_SERVICE_VERSION). This script
# bumps that variable from old_version to new_version for every instance
# currently on old_version (others are skipped), then pulls and redeploys.
#
# Can be run from any directory.

set -euo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

usage() {
    echo "Usage: $0 <service> <old_version> <new_version> [instance]"
    echo "  service       ndb-core | replication-backend | aam-services"
    echo "  old_version   only update instances currently on this version"
    echo "  new_version   version to set"
    echo "  instance      update only this instance (default: all ${PREFIX}* instances)"
    echo
    echo "Example: $0 ndb-core 3.5.0 3.6.0"
    exit 1
}

positional=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)  usage ;;
        -*) echo "Unknown option: $arg"; usage ;;
        *)  positional+=("$arg") ;;
    esac
done

if [ "${#positional[@]}" -lt 3 ] || [ "${#positional[@]}" -gt 4 ]; then
    usage
fi

SERVICE="${positional[0]}"
OLD_VERSION="${positional[1]}"
NEW_VERSION="${positional[2]}"
INSTANCE="${positional[3]:-}"

case "$SERVICE" in
    ndb-core)             VAR="APP_VERSION" ;;
    replication-backend)  VAR="AAM_REPLICATION_BACKEND_VERSION" ;;
    aam-services)         VAR="AAM_BACKEND_SERVICE_VERSION" ;;
    *) echo "Invalid service name. Use ndb-core, replication-backend, aam-services."; exit 1 ;;
esac

updated=0
skipped=0

update_instance() {
    local D="$1"
    local instance="${D##*/}"
    local envFile="$D/.env"

    if [ ! -f "$envFile" ]; then
        echo "[$instance] no .env, skipping"
        skipped=$((skipped + 1))
        return
    fi

    local current
    current=$(getVar "$envFile" "$VAR")

    if [ "$current" != "$OLD_VERSION" ]; then
        echo "[$instance] $VAR=${current:-<unset>} (not $OLD_VERSION), skipping"
        skipped=$((skipped + 1))
        return
    fi

    echo
    echo "[$instance] $VAR: $OLD_VERSION -> $NEW_VERSION"

    setEnv "$VAR" "$NEW_VERSION" "$envFile"

    echo "[$instance] redeploying..."
    if ! (cd "$D" && docker compose pull && docker compose up -d); then
        echo "[$instance] redeploy failed, rolling back to $VAR=$OLD_VERSION"
        setEnv "$VAR" "$OLD_VERSION" "$envFile"
        # Restore the previous runtime too, not just the config on disk.
        (cd "$D" && docker compose up -d) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed"
        return 1
    fi
    echo "[$instance] redeployed"
    updated=$((updated + 1))
}

forEachInstance update_instance "$INSTANCE"

echo
echo "Done. $updated updated, $skipped skipped."
