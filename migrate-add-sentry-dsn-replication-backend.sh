#!/bin/bash

# Migration: add SENTRY_DSN_REPLICATION_BACKEND to existing .env files
# (only for instances that already have TEMPLATE_VERSION=2 but are missing
# the SENTRY_DSN_REPLICATION_BACKEND variable).
#
# Run from the parent directory containing all instance folders
# (i.e. the directory that also contains the ndb-setup checkout).

set -u

# Load PREFIX, BWS_ACCESS_TOKEN (and other setup.env vars).
source "ndb-setup/setup.env"

if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set in ndb-setup/setup.env"
    exit 1
fi

if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    echo "ERROR: BWS_ACCESS_TOKEN is not set in ndb-setup/setup.env"
    exit 1
fi

# set server-base to EU instance (matches interactive-setup.sh)
bws config server-base https://vault.bitwarden.eu

SENTRY_DSN_REPLICATION_BACKEND=$(bws secret -t "$BWS_ACCESS_TOKEN" get "359ea1c0-798e-4e17-ae44-b2e20153051d" | jq -r .value)

for D in "${PREFIX}"*; do
    if [ -d "${D}" ]; then
        env_file="$D/.env"
        compose_file="$D/docker-compose.yml"

        if [ ! -f "$env_file" ]; then
            echo "[$D] no .env file, skipping"
            continue
        fi

        # Warn if the docker-compose.yml does not yet reference the new variable
        # (outdated compose file — env var would have no effect).
        if [ -f "$compose_file" ]; then
            if ! grep -q 'SENTRY_DSN_REPLICATION_BACKEND' "$compose_file"; then
                echo "[$D] WARNING: docker-compose.yml does not reference SENTRY_DSN_REPLICATION_BACKEND (outdated compose file)"
            fi
        else
            echo "[$D] WARNING: no docker-compose.yml found"
        fi

        # Only migrate instances already on TEMPLATE_VERSION=2
        if ! grep -q '^TEMPLATE_VERSION=2$' "$env_file"; then
            echo "[$D] TEMPLATE_VERSION!=2, skipping"
            continue
        fi

        # Skip if already present (regardless of value)
        if grep -q '^SENTRY_DSN_REPLICATION_BACKEND=' "$env_file"; then
            echo "[$D] SENTRY_DSN_REPLICATION_BACKEND already present, skipping"
            continue
        fi

        # Backup before editing
        cp "$env_file" "$env_file.bak"

        # Insert the new variable directly after the SENTRY_DSN= line if present,
        # otherwise append it to the end of the file.
        if grep -q '^SENTRY_DSN=' "$env_file"; then
            sed -i "/^SENTRY_DSN=.*/a SENTRY_DSN_REPLICATION_BACKEND=$SENTRY_DSN_REPLICATION_BACKEND" "$env_file"
        else
            printf '\nSENTRY_DSN_REPLICATION_BACKEND=%s\n' "$SENTRY_DSN_REPLICATION_BACKEND" >> "$env_file"
        fi

        echo "[$D] added SENTRY_DSN_REPLICATION_BACKEND= (backup: $env_file.bak)"
    fi
done
