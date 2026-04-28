#!/bin/bash

# Migration: add SENTRY_DSN_REPLICATION_BACKEND to existing .env files and
# update docker-compose.yml to use the new variable instead of SENTRY_DSN.
# Only processes instances that already have TEMPLATE_VERSION=2.
#
# Can be run from any directory.

set -u

# Load PREFIX, BWS_ACCESS_TOKEN (and other setup.env vars).
baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

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

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

for D in "$baseDirectory/${PREFIX}"*; do
    if [ -d "${D}" ]; then
        env_file="$D/.env"
        compose_file="$D/docker-compose.yml"

        if [ ! -f "$env_file" ]; then
            echo "  ... [$D] no .env file, skipping"
            continue
        fi

        # Migrate docker-compose.yml: replace `SENTRY_DSN: ${SENTRY_DSN}` with
        # `SENTRY_DSN: ${SENTRY_DSN_REPLICATION_BACKEND}` if not already updated.
        if [ ! -f "$compose_file" ]; then
            echo "[$D] WARNING: no docker-compose.yml found"
        elif grep -q 'SENTRY_DSN_REPLICATION_BACKEND' "$compose_file"; then
            echo "  ... [$D] docker-compose.yml already up to date"
        elif grep -q 'SENTRY_DSN: \${SENTRY_DSN}' "$compose_file"; then
            cp "$compose_file" "$compose_file.$TIMESTAMP.bak"
            sed -i 's|SENTRY_DSN: \${SENTRY_DSN}$|SENTRY_DSN: ${SENTRY_DSN_REPLICATION_BACKEND}|g' "$compose_file"
            echo "[$D] updated docker-compose.yml: SENTRY_DSN -> SENTRY_DSN_REPLICATION_BACKEND (backup: $compose_file.$TIMESTAMP.bak)"
        else
            echo "[$D] WARNING: docker-compose.yml does not reference SENTRY_DSN_REPLICATION_BACKEND and no known old pattern found — manual review needed"
        fi

        # Only migrate instances already on TEMPLATE_VERSION=2
        if ! grep -q '^TEMPLATE_VERSION=2$' "$env_file"; then
            echo "  ... [$D] TEMPLATE_VERSION!=2, skipping"
            continue
        fi

        # Skip if already present (regardless of value)
        if grep -q '^SENTRY_DSN_REPLICATION_BACKEND=' "$env_file"; then
            echo "  ... [$D] SENTRY_DSN_REPLICATION_BACKEND already present, skipping"
            continue
        fi

        # Backup before editing
        cp "$env_file" "$env_file.$TIMESTAMP.bak"

        # Insert the new variable directly after the SENTRY_DSN= line if present,
        # otherwise append it to the end of the file.
        if grep -q '^SENTRY_DSN=' "$env_file"; then
            sed -i "/^SENTRY_DSN=.*/a SENTRY_DSN_REPLICATION_BACKEND=$SENTRY_DSN_REPLICATION_BACKEND" "$env_file"
        else
            printf '\nSENTRY_DSN_REPLICATION_BACKEND=%s\n' "$SENTRY_DSN_REPLICATION_BACKEND" >> "$env_file"
        fi

        echo "[$D] added SENTRY_DSN_REPLICATION_BACKEND= (backup: $env_file.$TIMESTAMP.bak)"
    fi
done
