#!/bin/bash

# Enable (or disable) Sentry error logging for an instance.
# Idempotent: just (re)writes the relevant .env values.
#
# Usage:
#   ./enable-sentry.sh <instance> [y|n] [--skip-restart]
#     y (default) -> set the Sentry DSNs and enable logging for app + replication-backend
#     n           -> disable backend Sentry logging (SENTRY_LOGGING_ENABLED=false)
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   SENTRY_DSN_APP, SENTRY_DSN_REPLICATION_BACKEND

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart is accepted (and ignored: this script changes no running service), stripped from
# "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

##############################
# input
##############################

requireInstance "${1:-}"

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
