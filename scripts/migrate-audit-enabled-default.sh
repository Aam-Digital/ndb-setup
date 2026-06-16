#!/bin/bash

# Migration: change AUDIT_ENABLED default from false to true in docker-compose.yml
#
# For each instance with the configured PREFIX:
# - Updates REPLICATION_BACKEND_AUDIT_ENABLED default value in docker-compose.yml
#   from ${REPLICATION_BACKEND_AUDIT_ENABLED:-false} to ${REPLICATION_BACKEND_AUDIT_ENABLED:-true}
#
# Can be run from any directory.

set -uo pipefail

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set in ndb-setup/setup.env"
    exit 1
fi

migrate_instance() {
    local instanceDir="$1"
    local instance
    instance=$(basename "$instanceDir")
    instance=${instance#"$PREFIX"}

    local compose_file="$instanceDir/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        echo "[$instance] no docker-compose.yml found, skipping"
        return
    fi

    # Check if already migrated
    if ! grep -q '\${REPLICATION_BACKEND_AUDIT_ENABLED:-false}' "$compose_file"; then
        echo "[$instance] docker-compose.yml already up to date or pattern not found, skipping"
        return
    fi

    echo "[$instance] migrating..."

    # Backup before editing
    backupFile "$compose_file"

    # Replace the default from false to true
    sed -i 's/\${REPLICATION_BACKEND_AUDIT_ENABLED:-false}/\${REPLICATION_BACKEND_AUDIT_ENABLED:-true}/g' "$compose_file"

    echo "[$instance] updated AUDIT_ENABLED default to true (backup: ${BACKUP_FILE:-none})"
}

##############################
# main
##############################

if [ -n "${1:-}" ]; then
    # single instance mode
    path="$baseDirectory/${PREFIX:-}$1"
    if [ ! -d "$path" ]; then
        echo "Instance directory not found: $path"
        exit 1
    fi
    migrate_instance "$path"
else
    # all instances
    cd "$baseDirectory"
    for D in ${PREFIX}*; do
        if [ -d "$D" ]; then
            migrate_instance "$baseDirectory/$D"
        fi
    done
fi

echo "Migration complete."
