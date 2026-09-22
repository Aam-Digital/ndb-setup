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
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"

# FIREBASE_CREDENTIAL_BASE64 is resolved via getConfig/requireConfig (setup.env/environment, falling
# back to Bitwarden Secrets Manager - see lib/secrets.sh). It is the shared Firebase project's backend
# service-account credential (base64, same for every instance) the aam-backend-service uses to send
# pushes. The frontend web config (assets/firebase-config.json) needs no per-instance action any more:
# the ndb-core image ships the real shared config directly and nothing overwrites it.

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
if [ -z "$instance" ]; then
  instance="$(basename "$path")"
  instance="${instance#"$PREFIX"}"
fi

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

# Enable email notifications by default. Always pass --skip-restart: the email step writes its config but does
# not restart, so the single restart below applies both the notification and email config in one cycle.
# Pass $path (not $instance) so a custom instance location (outside the standard layout) is preserved.
"$scriptDir/enable-feature-notification-email.sh" "$path" --skip-restart

# Restart once, here, after both this script and the email step have written their config — unless the caller
# asked to skip it (interactive-setup restarts the stack itself after all enable-* scripts have run).
if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose down && docker compose up -d)
fi

echo "Feature enabled."
