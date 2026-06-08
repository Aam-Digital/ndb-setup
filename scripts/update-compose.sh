#!/bin/bash
# Update the docker-compose.yml of every instance to match the canonical
# ndb-setup/docker-compose.yml.
#
# Instances get a *copy* of docker-compose.yml at setup time, so structural
# changes to the canonical file (new service, changed volume, etc.) do not
# propagate automatically. This script previews the diff for each instance,
# asks for confirmation, backs up the old file and copies the new one.
#
# Can be run from any directory.

set -euo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

CANONICAL="$baseDirectory/ndb-setup/docker-compose.yml"
REDEPLOY=0
ASSUME_YES=0

usage() {
    echo "Usage: $0 [--redeploy] [--yes]"
    echo "  --redeploy  run 'docker compose up -d' after updating an instance"
    echo "  --yes       skip per-instance confirmation (still skips unchanged)"
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --redeploy) REDEPLOY=1 ;;
        --yes)      ASSUME_YES=1 ;;
        -h|--help)  usage ;;
        *) echo "Unknown option: $arg"; usage ;;
    esac
done

if [ ! -f "$CANONICAL" ]; then
    echo "Canonical compose file not found: $CANONICAL"
    exit 1
fi

updated=0
skipped=0

for D in "$baseDirectory/${PREFIX}"*; do
    [ -d "$D" ] || continue
    target="$D/docker-compose.yml"
    instance="${D##*/}"

    if [ ! -f "$target" ]; then
        echo "[$instance] no docker-compose.yml, skipping"
        skipped=$((skipped + 1))
        continue
    fi

    if diff -q "$target" "$CANONICAL" >/dev/null 2>&1; then
        echo "[$instance] already up to date"
        skipped=$((skipped + 1))
        continue
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
            *) echo "[$instance] skipped"; skipped=$((skipped + 1)); continue ;;
        esac
    fi

    backup="$target.bak.$(date +%Y%m%d%H%M%S)"
    cp "$target" "$backup"
    cp "$CANONICAL" "$target"
    echo "[$instance] updated (backup: $backup)"
    updated=$((updated + 1))

    if [ "$REDEPLOY" -eq 1 ]; then
        echo "[$instance] redeploying..."
        (cd "$D" && docker compose up -d)
        echo "[$instance] redeployed"
    fi
done

echo
echo "Done. $updated updated, $skipped skipped."
if [ "$updated" -gt 0 ] && [ "$REDEPLOY" -eq 0 ]; then
    echo "Note: run 'docker compose up -d' in the updated instances (or re-run with --redeploy) to apply."
fi
