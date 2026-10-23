#!/bin/bash
usage() {
  cat <<'EOF'
Enable (or disable) Sentry error logging of an instance: the app's DSN in its config.json
(remoteLoggingDsn), and the .env values of replication-backend and aam-backend-service.

Usage:
  ./enable-sentry.sh <instance> [y|n|repair] [--skip-restart]

  y       set the Sentry DSNs and enable logging of app and replication-backend (asked for if not given)
  n       disable Sentry logging: remove remoteLoggingDsn from config.json (app), SENTRY_ENABLED=false
          (replication-backend) in .env, and SENTRY_LOGGING_ENABLED=false for aam-backend-service
  repair  only set remoteLoggingDsn in config.json, unless config.json already has that key (e.g. a custom
          DSN) or Sentry was disabled with "n" (SENTRY_ENABLED=false in .env). Changes nothing else.

From app version 4.0 on, the app reports errors only when remoteLoggingDsn is set in config.json; older
versions reported to Aam Digital's Sentry by default. Before updating instances to 4.0, keep them reporting:
  ./for-each-instance.sh ./enable-sentry.sh repair
Without SENTRY_DSN_APP configured (e.g. self-hosted), "repair" leaves config.json as it is and the app
reports nothing. Non-production instances can set "remoteLoggingEnvironment" in config.json by hand.

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  SENTRY_DSN_APP, SENTRY_DSN_REPLICATION_BACKEND (only for y; repair only needs SENTRY_DSN_APP)

Re-running it rewrites these values and prints "Nothing to do" for an up-to-date config.json. It restarts
nothing: the app reads config.json when it is loaded in the browser (the file is changed in place, so the
running container serves it right away); the .env values take effect when the containers are recreated
('docker compose up -d' in the instance folder). Only "repair" is meant for for-each-instance.sh: y or n
would enable (or disable) Sentry on every instance.
EOF
  exit "${1:-1}"
}

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/app-config.sh"
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

appConfig="$path/config.json"
if [ ! -f "$appConfig" ]; then
  echo "ERROR: $appConfig not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to update $appConfig" >&2
  exit 1
fi
if ! jq -e 'type == "object"' "$appConfig" >/dev/null 2>&1; then
  echo "ERROR: $appConfig is not a JSON object, fix it first" >&2
  exit 1
fi

# Set the app's Sentry DSN in config.json, if it differs. Args: dsn
writeAppSentryDsn() {
  if [ "$(getAppConfig "$appConfig" remoteLoggingDsn)" == "$1" ]; then
    echo "  = config.json: remoteLoggingDsn up to date"
    return 0
  fi
  saveRollbackCopy "$appConfig" || exit 1
  setAppConfig "$appConfig" remoteLoggingDsn "$1" || exit 1
  # not printing the DSN: it is a credential of the Sentry project
  echo "  ~ config.json: set remoteLoggingDsn"
}

case "$enableSentry" in
  y|Y)
    requireConfig SENTRY_DSN_APP
    requireConfig SENTRY_DSN_REPLICATION_BACKEND
    writeAppSentryDsn "$SENTRY_DSN_APP"
    # upsertEnv, as instances created from an older .env.template may lack these keys
    upsertEnv SENTRY_DSN "$SENTRY_DSN_APP" "$path/.env"
    upsertEnv SENTRY_DSN_REPLICATION_BACKEND "$SENTRY_DSN_REPLICATION_BACKEND" "$path/.env"
    upsertEnv SENTRY_ENABLED "true" "$path/.env"
    upsertEnv SENTRY_ENVIRONMENT "production" "$path/.env"
    echo "Sentry logging enabled for '$org'."
    ;;
  repair)
    # The app had a built-in default DSN before version 4.0, so every instance reported unless disabled.
    # An existing remoteLoggingDsn key (also an empty one) is the instance's own choice and kept.
    sentryEnabled=$(getVar "$path/.env" SENTRY_ENABLED)
    sentryEnabled="${sentryEnabled//[\"\']/}"
    if [ "${sentryEnabled,,}" == "false" ]; then
      echo "Sentry logging is disabled for '$org' (SENTRY_ENABLED=false). Nothing to do."
      exit 0
    fi
    if hasAppConfig "$appConfig" remoteLoggingDsn; then
      echo "config.json of '$org' already sets remoteLoggingDsn. Nothing to do."
      exit 0
    fi
    if ! sentryDsn=$(getConfig SENTRY_DSN_APP); then
      echo "note: SENTRY_DSN_APP is not configured, so from app version 4.0 on '$org' reports no errors."
      exit 0
    fi
    writeAppSentryDsn "$sentryDsn"
    ;;
  n|N)
    # The app has no "enabled" switch, only its DSN. SENTRY_ENABLED=false marks the instance as deliberately
    # disabled, so "repair" does not set the DSN again.
    if hasAppConfig "$appConfig" remoteLoggingDsn; then
      saveRollbackCopy "$appConfig" || exit 1
      removeAppConfig "$appConfig" remoteLoggingDsn || exit 1
      echo "  - config.json: removed remoteLoggingDsn"
    fi
    upsertEnv SENTRY_DSN "" "$path/.env"
    upsertEnv SENTRY_ENABLED "false" "$path/.env"
    backendEnv="$path/config/aam-backend-service/application.env"
    if [ -f "$backendEnv" ]; then
      upsertEnv SENTRY_LOGGING_ENABLED "false" "$backendEnv"
    fi
    echo "Sentry logging disabled for '$org'."
    ;;
  *)
    echo "Invalid choice '$enableSentry'."
    usage
    ;;
esac
