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

# FIREBASE_CONFIG_JSON / FIREBASE_CREDENTIAL_BASE64 are resolved via getConfig/requireConfig
# (setup.env/environment, falling back to Bitwarden Secrets Manager - see lib/secrets.sh). They hold
# the shared Firebase project's credentials (the same ones are used for every instance):
#   - the frontend web config (firebase-config.json) the browser uses to register for push notifications.
#     The published ndb-core image does not contain it (the file is gitignored there), so it is written to
#     the instance's assets/ folder and volume-mounted into the app container.
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
if [ -z "$instance" ]; then
  instance="$(basename "$path")"
  instance="${instance#"$PREFIX"}"
fi

##############################
# variables
##############################

appEnv="$path/config/aam-backend-service/application.env"
composeFile="$path/docker-compose.yml"
# Kept under assets/ (not the instance root) so update-compose.sh re-creates the volume mount after it
# replaces docker-compose.yml with the canonical version (see ensureAssetVolumeMountsFromDir).
firebaseWebConfigFile="$path/assets/firebase-config.json"
# Pre-#121 instances had it in the instance root, mounted by the canonical docker-compose.yml back then.
legacyFirebaseWebConfigFile="$path/firebase-config.json"

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

# Resolve the frontend Firebase web config first (before anything is written), so a missing config aborts
# cleanly. Fall back to a valid legacy root-level file from before the mount was moved to assets/.
if firebaseWebConfigJson=$(getConfig FIREBASE_CONFIG_JSON) && isValidFirebaseWebConfig "$firebaseWebConfigJson"; then
  :
elif [ -f "$legacyFirebaseWebConfigFile" ] && isValidFirebaseWebConfig "$(cat "$legacyFirebaseWebConfigFile")"; then
  echo "  using legacy $(basename "$legacyFirebaseWebConfigFile") from the instance directory"
  firebaseWebConfigJson=$(cat "$legacyFirebaseWebConfigFile")
else
  echo "ERROR: No valid Firebase web config (firebase-config.json) available. Without it the app cannot"
  echo "       register browsers for push notifications. Provide FIREBASE_CONFIG_JSON (the JSON object with"
  echo "       apiKey, projectId, messagingSenderId, appId, ...) in setup.env / the environment, or set"
  echo "       BWS_ACCESS_TOKEN to load it from Bitwarden. Abort."
  exit 1
fi

# Write the frontend Firebase web config and volume-mount it into the app container (idempotent).
# Sets frontendConfigChanged=true if the file or the mount had to be created/updated.
frontendConfigChanged=false
mkdir -p "$(dirname "$firebaseWebConfigFile")"
newFirebaseWebConfig=$(printf '%s' "$firebaseWebConfigJson" | jq .)
if [ ! -f "$firebaseWebConfigFile" ] || [ "$(cat "$firebaseWebConfigFile")" != "$newFirebaseWebConfig" ]; then
  # No backupFile here: a backup inside assets/ would get volume-mounted (and served) as well, and the config
  # is the shared, non-secret Firebase web config that can always be re-created from FIREBASE_CONFIG_JSON.
  printf '%s\n' "$newFirebaseWebConfig" > "$firebaseWebConfigFile"
  chmod 644 "$firebaseWebConfigFile"   # read by the unprivileged nginx user in the app container
  echo "  ~ wrote assets/$(basename "$firebaseWebConfigFile") (frontend web push config)"
  frontendConfigChanged=true
fi
if ! grep -Eq "^[[:space:]]*- \./assets/firebase-config\.json:" "$composeFile"; then
  backupFile "$composeFile"
  frontendConfigChanged=true
fi
ensureAssetVolumeMount "$composeFile" "firebase-config.json"

# Already enabled: only the frontend config above may have been missing (e.g. instances whose mount was
# dropped when the canonical docker-compose.yml stopped mounting it). Apply that and stop here.
if [ "$isFeatureAlreadyEnabled" == "true" ]; then
  if [ "$frontendConfigChanged" == "true" ]; then
    if [ "$skipRestart" != "true" ]; then
      (cd "$path" && docker compose up -d)
    fi
    echo "Feature was already enabled; added the missing frontend Firebase config."
  else
    echo "Feature is already enabled for this instance. Nothing to do."
  fi
  exit 0
fi

# Resolve the backend Firebase service-account credential (base64). Prefer an explicit argument (e.g. for
# offline/testing), otherwise load it via getConfig (setup.env/environment, then Bitwarden). Because the same
# shared Firebase project is used for every instance, this is non-interactive and works during automated
# interactive-setup.
[ -n "$2" ] && FIREBASE_CREDENTIAL_BASE64="$2"
requireConfig FIREBASE_CREDENTIAL_BASE64 "Or pass it as the second argument: ./enable-feature-notification.sh <instance> <credential-base64>"
configCredentialBase64="$FIREBASE_CREDENTIAL_BASE64"

backupFile "$appEnv"

# upsertEnv (not setEnv): application.env files created from older aam-backend-service templates may lack
# some of these keys (LINKBASEURL is not in the template at all), so they have to be added if missing.
upsertEnv "NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64" "$configCredentialBase64" "$appEnv" || exit 1
upsertEnv "NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL" "https://$instance.$DOMAIN" "$appEnv" || exit 1
upsertEnv "FEATURES_NOTIFICATIONAPI_MODE" "firebase" "$appEnv" || exit 1
upsertEnv "FEATURES_NOTIFICATIONAPI_ENABLED" "true" "$appEnv" || exit 1

# Enable email notifications by default. Always pass --skip-restart: the email step writes its config but does
# not restart, so the single restart below applies both the notification and email config in one cycle.
# Pass $path (not $instance) so a custom instance location (outside the standard layout) is preserved.
# Abort (without restarting) if the email step fails, instead of reporting success with a half-applied config.
if ! "$scriptDir/enable-feature-notification-email.sh" "$path" --skip-restart; then
  echo "ERROR: Enabling email notifications failed (see above). Push notification config was written to"
  echo "       $(basename "$appEnv") but the instance was NOT restarted. Fix the issue and re-run"
  echo "       './enable-feature-notification-email.sh $instance' (it restarts the instance when done)."
  exit 1
fi

# Restart once, here, after both this script and the email step have written their config — unless the caller
# asked to skip it (interactive-setup restarts the stack itself after all enable-* scripts have run).
if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose down && docker compose up -d)
fi

echo "Feature enabled."
