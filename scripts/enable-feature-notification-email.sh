#!/bin/bash

# This script will enable email notifications for a customer instance.
# It requires the notification feature to already be enabled (run enable-feature-notification.sh first).

# how to use
# ./enable-feature-notification-email.sh <instance>
# example: ./enable-feature-notification-email.sh qm

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
appEnv="$path/config/aam-backend-service/application.env"

##############################
# script
##############################

if ! backendEnabledCheck; then
  echo "No backend found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
fi

if ! isBackendConfigCreated; then
  echo "No backend configuration found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
fi

isEmailAlreadyEnabled=$(getVar "$appEnv" FEATURES_NOTIFICATIONAPI_EMAIL_ENABLED)

if [ "$isEmailAlreadyEnabled" == "true" ]; then
  echo "Email notifications already enabled for instance '$instance'. Abort."
  exit 1
fi

echo ""
echo "Configuring email notifications for '$instance'..."

# Load SMTP credentials from setup.env if set, otherwise fetch from BWS
if [[ -z "${SMTP_SERVER:-}" || -z "${SMTP_PASSWORD:-}" ]]; then
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    echo "ERROR: SMTP_SERVER/SMTP_PASSWORD are not set in setup.env and BWS_ACCESS_TOKEN is not set. Abort."
    exit 1
  fi
  echo "Loading SMTP credentials from Bitwarden Secrets Manager..."
  bws config server-base https://vault.bitwarden.eu
  SMTP_SERVER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "55bf05ce-03ed-40fb-8320-b2ce00cf6760" 2>&1 | jq -r '.value // empty')
  SMTP_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "ec5d7f0a-62e3-46d7-a7c7-b2ce00cf8abc" 2>&1 | jq -r '.value // empty')
  if [[ -z "$SMTP_SERVER" || -z "$SMTP_PASSWORD" ]]; then
    echo "ERROR: Failed to load SMTP credentials from Bitwarden. The BWS_ACCESS_TOKEN may not have access to these secrets (they require the production service account token)."
    exit 1
  fi
fi

smtpHost="$SMTP_SERVER"
smtpPassword="$SMTP_PASSWORD"
smtpPort="465"
smtpUsername="accounts@aam-digital.com"
emailFrom="accounts@aam-digital.com"
subjectPrefix="Aam Digital"

(cd "$path" && docker compose down)

backupFile "$appEnv"

upsertEnv "FEATURES_NOTIFICATIONAPI_EMAIL_ENABLED" "true" "$appEnv"
upsertEnv "SPRING_MAIL_HOST" "$smtpHost" "$appEnv"
upsertEnv "SPRING_MAIL_PORT" "$smtpPort" "$appEnv"
upsertEnv "SPRING_MAIL_USERNAME" "$smtpUsername" "$appEnv"
upsertEnv "SPRING_MAIL_PASSWORD" "$smtpPassword" "$appEnv"
upsertEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_AUTH" "true" "$appEnv"
upsertEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_SSL_ENABLE" "true" "$appEnv"
upsertEnv "NOTIFICATION_EMAIL_FROM" "$emailFrom" "$appEnv"
upsertEnv "NOTIFICATION_EMAIL_SUBJECTPREFIX" "$subjectPrefix" "$appEnv"

(cd "$path" && docker compose up -d)

echo "Email notifications enabled."
