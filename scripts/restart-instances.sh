#!/bin/bash
# Restart all instance containers to pick up changed env vars or config.
# Runs `docker compose down && docker compose up -d` in each instance folder.
#
# Can be run from any directory.

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

for D in "$baseDirectory/${PREFIX}"*; do
    if [ -d "$D" ] && [ -f "$D/docker-compose.yml" ]; then
        instance="${D##*/}"
        echo "[$instance] restarting..."
        (cd "$D" && docker compose down && docker compose up -d)
        echo "[$instance] done"
    fi
done
