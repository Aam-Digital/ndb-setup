#!/bin/bash
# Delete the rollback copies scripts leave behind in an instance: the "<file>.rollback-<timestamp>" copies
# saveRollbackCopy (scripts/lib/common.sh) makes before changing .env, docker-compose.yml, application.env,
# ..., the "assets.rollback-<timestamp>" folders update-assets.sh makes, and the older names of both
# (".bak-<timestamp>", ".bak", "_backup", "-old"). Lists every match and asks for confirmation first.
# (These are not backups: system backups are backup.sh's encrypted archives.)
#
# Usage:
#   ./prune-rollback-copies.sh <instance> [--yes]
#     --yes  delete without asking for confirmation
# For all instances: ./for-each-instance.sh ./prune-rollback-copies.sh [--yes]
#
# Can be run from any directory.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

ASSUME_YES=0
INSTANCE=""

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

for arg in "$@"; do
    case "$arg" in
        --yes)     ASSUME_YES=1 ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $arg"; usage ;;
        *)  INSTANCE="$arg" ;;
    esac
done

[ -n "$INSTANCE" ] || usage
requireInstance "$INSTANCE"

# Collect the rollback copies of the instance (the CouchDB data and service storage are not searched).
copies=()
while IFS= read -r -d '' f; do
    copies+=("$f")
done < <(find "$path" \( -path "$path/couchdb" -o -path "$path/storage" \) -prune -o \( \
    \( -type f \( -name '*.rollback-[0-9]*' \
        -o -name '.env.bak-*' -o -name 'docker-compose.yml.bak-*' -o -name 'application.env.bak-*' \
        -o -name 'application.env_backup' -o -name 'docker-compose.yml.bak' \
        -o -name '.env.*.bak' -o -name 'docker-compose.yml.*.bak' \
        -o -name '.env-old' -o -name 'docker-compose.yml-old' \) \) \
    -o \( -type d \( -name 'assets.rollback-[0-9]*' -o -name 'assets.bak' \) \) \
    \) -print0)

if [ "${#copies[@]}" -eq 0 ]; then
    echo "No rollback copies found."
    exit 0
fi

echo "Found ${#copies[@]} rollback cop$([ "${#copies[@]}" -eq 1 ] && echo y || echo ies):"
for f in "${copies[@]}"; do
    [ -d "$f" ] && echo "  $f/ (folder)" || echo "  $f"
done

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    read -r -p "Delete them? [y/N] " reply < /dev/tty
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted, nothing deleted."; exit 0 ;;
    esac
fi

rm -rf -- "${copies[@]}"
echo "Deleted ${#copies[@]} rollback cop$([ "${#copies[@]}" -eq 1 ] && echo y || echo ies)."
