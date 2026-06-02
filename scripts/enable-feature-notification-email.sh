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

if [[ -n "${BWS_ACCESS_TOKEN}" ]]; then
  echo "Loading SMTP credentials from Bitwarden Secrets Manager..."
  bws config server-base https://vault.bitwarden.eu
  smtpHost=$(bws secret -t "$BWS_ACCESS_TOKEN" get "55bf05ce-03ed-40fb-8320-b2ce00cf6760" | jq -r .value)
  smtpPassword=$(bws secret -t "$BWS_ACCESS_TOKEN" get "ec5d7f0a-62e3-46d7-a7c7-b2ce00cf8abc" | jq -r .value)
  smtpPort="587"
  smtpUsername="accounts@aam-digital.com"
  emailFrom="accounts@aam-digital.com"
  subjectPrefix="Aam Digital"
else
  echo "BWS_ACCESS_TOKEN not set. Please provide SMTP server details manually:"
  read -r -p "SMTP host: " smtpHost
  read -r -p "SMTP port [587]: " smtpPort
  smtpPort="${smtpPort:-587}"
  read -r -p "SMTP username: " smtpUsername
  read -r -s -p "SMTP password: " smtpPassword
  echo ""
  read -r -p "From address (e.g. noreply@$instance.$DOMAIN): " emailFrom
  emailFrom="${emailFrom:-noreply@$instance.$DOMAIN}"
  read -r -p "Subject prefix [Aam Digital]: " subjectPrefix
  subjectPrefix="${subjectPrefix:-Aam Digital}"
fi

(cd "$path" && docker compose down)

backupFile "$appEnv"

setEnv "FEATURES_NOTIFICATIONAPI_EMAIL_ENABLED" "true" "$appEnv"
setEnv "SPRING_MAIL_HOST" "$smtpHost" "$appEnv"
setEnv "SPRING_MAIL_PORT" "$smtpPort" "$appEnv"
setEnv "SPRING_MAIL_USERNAME" "$smtpUsername" "$appEnv"
setEnv "SPRING_MAIL_PASSWORD" "$smtpPassword" "$appEnv"
setEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_AUTH" "true" "$appEnv"
setEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_STARTTLS_ENABLE" "true" "$appEnv"
setEnv "NOTIFICATION_EMAIL_FROM" "$emailFrom" "$appEnv"
setEnv "NOTIFICATION_EMAIL_SUBJECTPREFIX" "$subjectPrefix" "$appEnv"

(cd "$path" && docker compose up -d)

echo "Email notifications enabled."
