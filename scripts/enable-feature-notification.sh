#!/bin/bash

# This script will enable the notification feature for an customer instance.

# how to use
# ./enable-feature-notification.sh <instance>
# example: ./enable-feature-notification.sh qm
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/secrets.sh"

# FIREBASE_CONFIG_JSON / FIREBASE_CREDENTIAL_BASE64 are resolved via getConfig/requireConfig
# (setup.env/environment, falling back to Bitwarden Secrets Manager - see lib/secrets.sh). They hold
# the shared Firebase project's credentials (the same ones are used for every instance):
#   - the frontend web config (firebase-config.json) the browser uses to register for push notifications
#   - the backend service-account credential (base64) the aam-backend-service uses to send pushes

##############################
# parse flags
##############################

# --skip-restart: do not restart docker at the end; the caller (e.g. interactive-setup.sh) restarts the stack
# once after all enable-* scripts have written their config. Run standalone the script restarts itself.
# Flags are stripped here so positional args stay intact.
skipRestart=false
positionalArgs=()
for arg in "$@"; do
  case "$arg" in
    --skip-restart) skipRestart=true ;;
    *) positionalArgs+=("$arg") ;;
  esac
done
set -- "${positionalArgs[@]+"${positionalArgs[@]}"}"

##############################
# ask for input data
##############################

if [ -n "$1" ]; then
  instanceArg="$1"
else
  echo "Which instance? (name, or path to the instance directory, e.g. '.')"
  read -r instanceArg
fi
resolveInstancePath "$instanceArg" || exit 1
instance=$(getVar "$path/.env" INSTANCE_NAME)
[ -n "$instance" ] || instance="${instanceArg#"$PREFIX"}"

##############################
# variables
##############################

appEnv="$path/config/aam-backend-service/application.env"

##############################
# script
##############################

# check if backend is already enabled for this instance
if ! backendEnabledCheck; then
  echo "No backend found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
fi

if ! isBackendConfigCreated; then
  echo "No backend configuration found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
fi

isFeatureAlreadyEnabled=$(getVar "$appEnv" FEATURES_NOTIFICATIONAPI_ENABLED)

if [ "$isFeatureAlreadyEnabled" == "true" ]; then
  echo "Feature is already enabled for this instance. Abort."
  exit 1
fi

# Resolve the backend Firebase service-account credential (base64). Prefer an explicit argument (e.g. for
# offline/testing), otherwise load it via getConfig (setup.env/environment, then Bitwarden). Because the same
# shared Firebase project is used for every instance, this is non-interactive and works during automated
# interactive-setup.
[ -n "$2" ] && FIREBASE_CREDENTIAL_BASE64="$2"
requireConfig FIREBASE_CREDENTIAL_BASE64 "Or pass it as the second argument: ./enable-feature-notification.sh <instance> <credential-base64>"
configCredentialBase64="$FIREBASE_CREDENTIAL_BASE64"

backupFile "$appEnv"

setEnv "NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64" "$configCredentialBase64" "$appEnv"
setEnv "NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL" "https://$instance.$DOMAIN" "$appEnv"
setEnv "FEATURES_NOTIFICATIONAPI_MODE" "firebase" "$appEnv"
setEnv "FEATURES_NOTIFICATIONAPI_ENABLED" "true" "$appEnv"

# Write the frontend Firebase web config the browser uses to register for push notifications. Loaded as a
# single JSON blob (shared Firebase project) and written to the file docker-compose mounts into the app
# container (assets/firebase-config.json), replacing the empty template copied during interactive-setup.
# Non-fatal when unresolved: leave the existing file in place rather than aborting the whole feature enable.
if firebaseConfigJson=$(getConfig FIREBASE_CONFIG_JSON); then
  if ! printf '%s' "$firebaseConfigJson" | jq empty 2>/dev/null; then
    echo "ERROR: Retrieved firebase-config.json is not valid JSON. Abort."
    exit 1
  fi

  backupFile "$path/firebase-config.json"
  printf '%s' "$firebaseConfigJson" > "$path/firebase-config.json"
  echo "  ~ wrote firebase-config.json (frontend web push config)"
else
  echo "WARNING: Could not resolve firebase-config.json (FIREBASE_CONFIG_JSON not set and not found in Bitwarden); leaving existing file in place."
fi

# Enable email notifications by default. Always pass --skip-restart: the email step writes its config but does
# not restart, so the single restart below applies both the notification and email config in one cycle.
"$baseDirectory/ndb-setup/scripts/enable-feature-notification-email.sh" "$instance" --skip-restart

# Restart once, here, after both this script and the email step have written their config — unless the caller
# asked to skip it (interactive-setup restarts the stack itself after all enable-* scripts have run).
if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose down && docker compose up -d)
fi

echo "Feature enabled."
