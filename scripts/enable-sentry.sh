#!/bin/bash
usage() {
  cat <<'EOF'
Enable (or disable) Sentry error logging of an instance, by (re)writing its .env values.

Usage:
  ./enable-sentry.sh <instance> [y|n] [--skip-restart]

  y  set the Sentry DSNs and enable logging of app and replication-backend (asked for if not given)
  n  disable the backend Sentry logging (SENTRY_LOGGING_ENABLED=false)

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  SENTRY_DSN_APP, SENTRY_DSN_REPLICATION_BACKEND
EOF
  exit "${1:-1}"
}

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
