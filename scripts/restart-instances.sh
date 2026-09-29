#!/bin/bash
# Restart all instance containers to pick up changed env vars or config.
# Runs `docker compose down && docker compose up -d` in each instance folder.
#
# Can be run from any directory.

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$scriptDir/for-each-instance.sh" --in-dir sh -c 'docker compose down && docker compose up -d'
