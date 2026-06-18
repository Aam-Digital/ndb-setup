#!/bin/bash

# Migration: add webmaster_email to existing per-instance config.json files.
#
# ndb-core reads environment.webmaster_email and passes it as the Nominatim
# API `email` parameter (required by Nominatim usage policy). This field is
# set via config.json so each instance carries its own contact email.
#
# Reads WEBMASTER_EMAIL from setup.env.
#
# Can be run from any directory.

set -eu

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set in ndb-setup/setup.env"
    exit 1
fi

if [ -z "${WEBMASTER_EMAIL:-}" ]; then
    echo "ERROR: WEBMASTER_EMAIL is not set in ndb-setup/setup.env"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

for D in "$baseDirectory/${PREFIX}"*; do
    if [ ! -d "$D" ]; then
        continue
    fi

    config_file="$D/config.json"

    if [ ! -f "$config_file" ]; then
        echo "  ... [$D] no config.json found, skipping"
        continue
    fi

    if jq -e 'has("webmaster_email")' "$config_file" > /dev/null 2>&1; then
        echo "  ... [$D] webmaster_email already present, skipping"
        continue
    fi

    cp "$config_file" "$config_file.$TIMESTAMP.bak"
    tmp=$(mktemp)
    jq --arg email "$WEBMASTER_EMAIL" '. + {webmaster_email: $email}' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    echo "[$D] added webmaster_email=$WEBMASTER_EMAIL (backup: $config_file.$TIMESTAMP.bak)"
done
