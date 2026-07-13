#!/bin/bash

# Create the instance directory and its base configuration (.env, couchdb.ini, docker-compose.yml, ...)
# and apply the selected baseConfig overlay. Does NOT touch Keycloak or start any container.
# Idempotent: existing files are never overwritten and generated secrets / versions are written only once,
# so re-running never regenerates the CouchDB password or bumps versions of an existing instance.
#
# Usage:
#   ./create-instance.sh <instance> [baseConfig]
#
# No secrets required. Reads DOMAIN / PREFIX from setup.env.

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"

##############################
# input
##############################

if [ -n "$1" ]; then
  org="$1"
else
  echo "What is the name of the organisation?"
  read -r org
fi
# keycloak realms are case sensitive elsewhere, so keep the name lowercase everywhere
org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

if grep -Fxq "$org" "$scriptDir/blacklist.txt"; then
  echo "Error: The organisation name '$org' is blacklisted. Please try another one."
  exit 1
fi
if [ ${#org} -ge 24 ]; then
  echo "Error: The organisation name must have less than 24 letters. Please try a shorter one."
  exit 1
fi

# baseConfig (optional)
if [ -n "$2" ]; then
  baseConfig="$2"
else
  echo "Which basic config do you want to include? (e.g. [default], basic, codo, ...)"
  read -r baseConfig
  [ -n "$baseConfig" ] || baseConfig=default
fi
if [ ! -d "$ndbSetupDir/baseConfigs/$baseConfig" ]; then
  echo "ERROR Invalid base config '$baseConfig'. Abort."
  exit 1
fi

path="$baseDirectory/$PREFIX$org"
url=$org.$DOMAIN

##############################
# instance directory + template files
##############################

echo "Setting up instance directory for '$org' at $path"
mkdir -p "$path"
mkdir -p "$path/couchdb/data"

# copy template files, but never overwrite an existing (possibly customized) file
for f in couchdb.ini config.json docker-compose.yml firebase-config.json; do
  if [ ! -f "$path/$f" ]; then
    cp "$ndbSetupDir/$f" "$path/$f"
    echo "  + copied $f"
  else
    echo "  = $f already exists, keeping it"
  fi
done

# the instance .env is generated from .env.template (note the different source name)
if [ ! -f "$path/.env" ]; then
  cp "$ndbSetupDir/.env.template" "$path/.env"
  echo "  + copied .env (from .env.template)"
else
  echo "  = .env already exists, keeping it"
fi

##############################
# base .env values
##############################

# deterministic identity values (upsert so they are written even into a partial .env)
upsertEnv INSTANCE_NAME "$org" "$path/.env"
upsertEnv INSTANCE_DOMAIN "$DOMAIN" "$path/.env"

# write-once values: keep whatever an existing instance already has (see ensureRealValue)
ensureRealValue COUCHDB_USER "aam-admin" "$path/.env"
ensureRealValue COUCHDB_PASSWORD "$(generate_password)" "$path/.env"
ensureRealValue REPLICATION_BACKEND_JWT_SECRET "$(generate_password)" "$path/.env"
ensureRealValue COMPOSE_PROFILES "database-only" "$path/.env"

# versions: pin to the latest available release once; keep an existing instance's pinned versions
ensureRealValue APP_VERSION \
  "$(curl -s https://api.github.com/repos/Aam-Digital/ndb-core/releases | jq -r 'map(select(.name | test("-") | not)) | .[0].name')" \
  "$path/.env"
ensureRealValue AAM_REPLICATION_BACKEND_VERSION \
  "$(curl -s https://api.github.com/repos/Aam-Digital/replication-backend/releases | jq -r 'map(select(.name | test("-") | not)) | .[0].name')" \
  "$path/.env"
ensureRealValue AAM_BACKEND_SERVICE_VERSION "$(getLatestBackendVersion)" "$path/.env"

##############################
# baseConfig overlay
##############################

# to add config or other docs to CouchDB, mount them to the assets/base-configs folder of ndb-core
# and use an `available-configs.json` entry to make it selectable in the app
# see https://github.com/Aam-Digital/ndb-core/blob/master/src/assets/base-configs/available-configs.json
if [ -d "$ndbSetupDir/baseConfigs/$baseConfig/assets" ]; then
  "$scriptDir/enable-assets-overwrites.sh" "$org" "$baseConfig"
fi

# Apply a config overlay shipped by the baseConfig. The baseConfig's `config/` folder mirrors the
# instance `config/` tree 1:1 and is copied verbatim, so e.g. a custom notification email template at
# `config/aam-backend-service/templates/notification/create-notification-email-template.html` lands at
# the path docker-compose mounts into the aam-backend-service container (/opt/app/templates).
# Note: this only adds files (e.g. templates/); the per-instance application.env is generated later by
# enable-backend.sh, so the two never collide.
if [ -d "$ndbSetupDir/baseConfigs/$baseConfig/config" ]; then
  echo "Applying config overlay from baseConfig '$baseConfig'..."
  mkdir -p "$path/config"
  cp -r "$ndbSetupDir/baseConfigs/$baseConfig/config/." "$path/config/"
fi

echo "Instance '$org' prepared. App URL: https://$url"
