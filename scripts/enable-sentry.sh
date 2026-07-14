#!/bin/bash

# Enable (or disable) Sentry error logging for an instance.
# Idempotent: just (re)writes the relevant .env values.
#
# Usage:
#   ./enable-sentry.sh <instance> [y|n]
#     y (default) -> set the Sentry DSNs and enable logging for app + replication-backend
#     n           -> disable backend Sentry logging (SENTRY_LOGGING_ENABLED=false)
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   SENTRY_DSN_APP, SENTRY_DSN_REPLICATION_BACKEND

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
  instanceArg="$1"
else
  echo "Which instance? (name, or path to the instance directory, e.g. '.')"
  read -r instanceArg
fi
resolveInstancePath "$instanceArg" || exit 1
if [ ! -d "$path" ]; then
  echo "ERROR: instance directory not found: $path (run create-instance.sh first). Abort."
  exit 1
fi
org=$(getVar "$path/.env" INSTANCE_NAME)

if [ -n "$2" ]; then
  enableSentry="$2"
else
  echo "Do you want to enable Sentry logging?[y/n]"
  read -r enableSentry
fi

##############################
# script
##############################

if [ "$enableSentry" == "y" ] || [ "$enableSentry" == "Y" ]; then
  requireConfig SENTRY_DSN_APP
  requireConfig SENTRY_DSN_REPLICATION_BACKEND
  setEnv SENTRY_DSN "$SENTRY_DSN_APP" "$path/.env"
  setEnv SENTRY_DSN_REPLICATION_BACKEND "$SENTRY_DSN_REPLICATION_BACKEND" "$path/.env"
  setEnv SENTRY_ENABLED "true" "$path/.env"
  setEnv SENTRY_ENVIRONMENT "production" "$path/.env"
  echo "Sentry logging enabled for '$org'."
else
  backendEnv="$path/config/aam-backend-service/application.env"
  if [ -f "$backendEnv" ]; then
    upsertEnv SENTRY_LOGGING_ENABLED "false" "$backendEnv"
  fi
  echo "Sentry logging disabled for '$org'."
fi
