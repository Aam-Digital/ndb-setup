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

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

# Bitwarden Secrets Manager key names for the shared Firebase project (the same Firebase credentials are used
# for every instance). Looked up by name via getBwsSecretByKey:
#   - the frontend web config (firebase-config.json) the browser uses to register for push notifications
#   - the backend service-account credential (base64) the aam-backend-service uses to send pushes
BWS_SECRET_FIREBASE_CONFIG_JSON="FIREBASE_CONFIG_JSON"
BWS_SECRET_FIREBASE_CREDENTIAL_BASE64="FIREBASE_CREDENTIAL_BASE64"

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
  instance="$1"
else
  echo "What is the name of the instance?"
  read -r instance
fi

##############################
# variables
##############################

path="$baseDirectory/$PREFIX$instance"
appEnv="$path/config/aam-backend-service/application.env"

# Point bws at the EU vault once up front so the secret lookups below work (no-op when no token is set).
if [ -n "${BWS_ACCESS_TOKEN}" ]; then
  bws config server-base https://vault.bitwarden.eu
fi

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
# offline/testing), otherwise load it from the Bitwarden Secrets Manager. Because the same shared Firebase
# project is used for every instance, this is non-interactive and works during automated interactive-setup.
if [ -n "$2" ]; then
  configCredentialBase64="$2"
else
  if [[ -z "${BWS_ACCESS_TOKEN}" ]]; then
    echo "BWS_ACCESS_TOKEN is not set and no credential argument was given. Abort."
    exit 1
  fi
  configCredentialBase64=$(getBwsSecretByKey "$BWS_SECRET_FIREBASE_CREDENTIAL_BASE64")
  if [[ -z "$configCredentialBase64" ]]; then
    echo "ERROR: Could not load the Firebase credential from Bitwarden (secret '$BWS_SECRET_FIREBASE_CREDENTIAL_BASE64'). Abort."
    exit 1
  fi
fi

backupFile "$appEnv"

setEnv "NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64" "$configCredentialBase64" "$appEnv"
setEnv "NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL" "https://$instance.$DOMAIN" "$appEnv"
setEnv "FEATURES_NOTIFICATIONAPI_MODE" "firebase" "$appEnv"
setEnv "FEATURES_NOTIFICATIONAPI_ENABLED" "true" "$appEnv"

# Write the frontend Firebase web config the browser uses to register for push notifications. Loaded as a
# single JSON blob from BWS (shared Firebase project) and written to the file docker-compose mounts into the
# app container (assets/firebase-config.json), replacing the empty template copied during interactive-setup.
if [ -n "${BWS_ACCESS_TOKEN}" ]; then
  firebaseConfigJson=$(getBwsSecretByKey "$BWS_SECRET_FIREBASE_CONFIG_JSON")
  if [[ -z "$firebaseConfigJson" ]]; then
    echo "WARNING: Could not load firebase-config.json from Bitwarden (secret '$BWS_SECRET_FIREBASE_CONFIG_JSON'); leaving existing file in place."
  else
    if ! printf '%s' "$firebaseConfigJson" | jq empty 2>/dev/null; then
      echo "ERROR: Retrieved firebase-config.json is not valid JSON. Abort."
      exit 1
    fi

    backupFile "$path/firebase-config.json"
    printf '%s' "$firebaseConfigJson" > "$path/firebase-config.json"
    echo "  ~ wrote firebase-config.json (frontend web push config)"
  fi
else
  echo "WARNING: BWS_ACCESS_TOKEN not set; leaving existing firebase-config.json in place."
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
