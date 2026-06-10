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

isFeatureAlreadyEnabled=$(getVar "$path/config/aam-backend-service/application.env" FEATURES_NOTIFICATIONAPI_ENABLED)

if [ "$isFeatureAlreadyEnabled" == "true" ]; then
  echo "Feature is already enabled for this instance. Abort."
  exit 1
else
  echo ""
fi

(cd "$path" && docker compose down)

backupFile "$path/config/aam-backend-service/application.env"

if [ -n "$2" ]; then
  configCredentialBase64="$2"
else
  echo "Insert value for NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64:"
  read -r configCredentialBase64
fi

setEnv "NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64" "$configCredentialBase64" "$path/config/aam-backend-service/application.env"
setEnv "NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL" "https://$instance.$DOMAIN" "$path/config/aam-backend-service/application.env"
# base URL used for email "manage settings" + notification action links (NotificationConfiguration uses application.base-url)
setEnv "APPLICATION_BASEURL" "https://$instance.$DOMAIN" "$path/config/aam-backend-service/application.env"
setEnv "FEATURES_NOTIFICATIONAPI_MODE" "firebase" "$path/config/aam-backend-service/application.env"
setEnv "FEATURES_NOTIFICATIONAPI_ENABLED" "true" "$path/config/aam-backend-service/application.env"

(cd "$path" && docker compose up -d)

echo "Feature enabled."

# Enable email notifications by default
"$baseDirectory/ndb-setup/scripts/enable-feature-notification-email.sh" "$instance"
