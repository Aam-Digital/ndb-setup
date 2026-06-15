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
# Can be run from any directory.

set -euo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

CANONICAL="$baseDirectory/ndb-setup/docker-compose.yml"
ASSUME_YES=0
INSTANCE=""

usage() {
    echo "Usage: $0 [--yes] [--overwrite-icons] [instance]"
    echo "  instance          update only this instance (default: all ${PREFIX}* instances)"
    echo "  --yes             skip per-instance confirmation (still skips unchanged)"
    echo "  --overwrite-icons enable custom icons mount in docker-compose.yml"
    exit 1
}

OVERWRITE_ICONS=0

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

    # Process optional features
    if [ "$OVERWRITE_ICONS" -eq 1 ]; then
        sed -i 's|# - ./assets/icons:/usr/share/nginx/html/assets/icons|      - ./assets/icons:/usr/share/nginx/html/assets/icons|' "$target"
    fi

    echo "[$instance] updated"

    echo "[$instance] redeploying..."
    if ! (cd "$D" && docker compose up -d); then
        echo "[$instance] redeploy failed, rolling back docker-compose.yml and redeploying previous config"
        cp "$previous" "$target"
        (cd "$D" && docker compose up -d) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed"
        return 1
    fi
    echo "[$instance] redeployed"
    updated=$((updated + 1))
}

forEachInstance update_instance "$INSTANCE"

echo
echo "Done. $updated updated, $skipped skipped."
