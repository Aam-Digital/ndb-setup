#!/bin/bash
usage() {
  cat <<'EOF'
Enable (or disable) Sentry error logging of an instance, by (re)writing its .env values.

Usage:
  ./enable-sentry.sh <instance> [y|n] [--skip-restart]

  y  set the Sentry DSNs and enable logging of app and replication-backend (asked for if not given)
  n  disable Sentry logging: empty SENTRY_DSN (app) and SENTRY_ENABLED=false (replication-backend) in .env,
     and SENTRY_LOGGING_ENABLED=false for aam-backend-service

From app version 4.0 on, the app reports errors only when SENTRY_DSN is set in .env (and passed to the app
by docker-compose.yml, see update-compose.sh); older versions reported to Aam Digital's Sentry by default.
SENTRY_ENABLED=false also keeps update-compose.sh from filling in SENTRY_DSN again.

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  SENTRY_DSN_APP, SENTRY_DSN_REPLICATION_BACKEND (only for y)

Re-running it rewrites these values. It changes no running service: the change takes effect when the
containers are recreated ('docker compose up -d' in the instance folder). Existing instances get SENTRY_DSN
filled in by update-compose.sh, so this is not meant to be rolled out with for-each-instance.sh, which
would enable (or disable) Sentry on every instance.
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
  # upsertEnv, as instances created from an older .env.template may lack these keys
  upsertEnv SENTRY_DSN "$SENTRY_DSN_APP" "$path/.env"
  upsertEnv SENTRY_DSN_REPLICATION_BACKEND "$SENTRY_DSN_REPLICATION_BACKEND" "$path/.env"
  upsertEnv SENTRY_ENABLED "true" "$path/.env"
  upsertEnv SENTRY_ENVIRONMENT "production" "$path/.env"
  echo "Sentry logging enabled for '$org'."
else
  # The app has no "enabled" switch, only its DSN (see docker-compose.yml). SENTRY_ENABLED=false marks the
  # instance as deliberately disabled, so update-compose.sh does not fill in SENTRY_DSN again.
  upsertEnv SENTRY_DSN "" "$path/.env"
  upsertEnv SENTRY_ENABLED "false" "$path/.env"
  backendEnv="$path/config/aam-backend-service/application.env"
  if [ -f "$backendEnv" ]; then
    upsertEnv SENTRY_LOGGING_ENABLED "false" "$backendEnv"
  fi
  echo "Sentry logging disabled for '$org'."
fi
