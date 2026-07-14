#!/bin/bash
# Prune backup files left behind by migration / update scripts across all
# instances: docker-compose.yml, .env and the backend config (application.env).
#
# These backups are created by backupFile() in scripts/lib/common.sh
# (named "<file>.bak-<timestamp>") and by older scripts as
# "application.env_backup". This lists every match, asks for confirmation
# and then deletes them.
#
# Can be run from any directory.

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

ASSUME_YES=0
INSTANCE=""

usage() {
    echo "Usage: $0 [--yes] [instance]"
    echo "  instance  prune only this instance (default: all ${PREFIX}* instances)"
    echo "  --yes     delete without asking for confirmation"
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --yes)     ASSUME_YES=1 ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $arg"; usage ;;
        *)  INSTANCE="$arg" ;;
    esac
done

# Collect every backup file across the selected instance(s).
backups=()
collect_backups() {
    local D="$1"
    while IFS= read -r -d '' f; do
        backups+=("$f")
    done < <(find "$D" \
        \( -name 'docker-compose.yml.bak-*' \
        -o -name '.env.bak-*' \
        -o -name 'application.env.bak-*' \
        -o -name 'application.env_backup' \) \
        -type f -print0)
}

forEachInstance collect_backups "$INSTANCE"

if [ "${#backups[@]}" -eq 0 ]; then
    echo "No backup files found."
    exit 0
fi

echo "Found ${#backups[@]} backup file(s):"
for f in "${backups[@]}"; do
    echo "  $f"
done

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    read -r -p "Delete all ${#backups[@]} file(s)? [y/N] " reply < /dev/tty
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted, nothing deleted."; exit 0 ;;
    esac
fi

for f in "${backups[@]}"; do
    rm -f "$f"
done

echo "Deleted ${#backups[@]} backup file(s)."
