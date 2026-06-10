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
existingKeycloakServerUrl=$(getVar "$appEnv" KEYCLOAK_SERVERURL)
existingMailHost=$(getVar "$appEnv" SPRING_MAIL_HOST)

# Idempotent: if email is already enabled AND the Keycloak admin client is configured, we are done.
# Otherwise (re-)configure, which also repairs partial setups left by older versions of this script
# that enabled email but never set the KEYCLOAK_* vars. Without those the EmailCreateNotificationHandler
# bean is never created (see aam-services NotificationConfiguration.kt) and email notifications are
# silently skipped.
if [ "$isEmailAlreadyEnabled" == "true" ] && [ -n "$existingKeycloakServerUrl" ]; then
  echo "Email notifications already fully configured for instance '$instance'. Nothing to do."
  exit 0
fi

# Derive the Keycloak admin client config required for the email handler to exist. It uses Keycloak to
# resolve recipient email addresses, so we reuse the aam-backend service-account client created by
# enable-backend.sh (its service account already has the realm-management view-users role).
#
# Resolve the server URL from KEYCLOAK_URL in the instance .env — the exact endpoint the
# replication-backend already uses for admin operations against this realm with the same client/secret,
# so it is known to work. Fall back to the backend's issuer URI for older instances predating KEYCLOAK_URL.
keycloakHost=$(getVar "$path/.env" KEYCLOAK_URL)
if [ -n "$keycloakHost" ]; then
  keycloakServerUrl="https://$keycloakHost"
else
  issuerUri=$(getVar "$appEnv" SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI)
  keycloakServerUrl="${issuerUri%/realms/*}"
  if [ -z "$issuerUri" ] || [ "$keycloakServerUrl" == "$issuerUri" ]; then
    echo "ERROR: Could not determine the Keycloak server URL (KEYCLOAK_URL missing in $path/.env and"
    echo "       SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI not parseable in the backend config)."
    echo "       Run './enable-backend.sh $instance' first."
    exit 1
  fi
fi
keycloakRealm="$instance"
keycloakClientId=$(getVar "$path/.env" REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID "aam-backend")
keycloakClientSecret=$(getVar "$path/.env" REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET)

if [ -z "$keycloakClientSecret" ]; then
  echo "ERROR: REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET is missing in $path/.env."
  echo "       This secret (aam-backend service account) is needed to look up recipient emails in Keycloak."
  echo "       Run './enable-backend.sh $instance' (or './migrate-notifications-permission-check.sh $instance') first."
  exit 1
fi

echo ""
if [ "$isEmailAlreadyEnabled" == "true" ]; then
  echo "Email is enabled but the Keycloak admin client is not configured — repairing '$instance'..."
else
  echo "Configuring email notifications for '$instance'..."
fi

(cd "$path" && docker compose down)

backupFile "$appEnv"

# Configure SMTP only when not already set, so re-runs/repairs keep existing (possibly customized) mail settings.
if [ -z "$existingMailHost" ]; then
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

  upsertEnv "SPRING_MAIL_HOST" "$smtpHost" "$appEnv"
  upsertEnv "SPRING_MAIL_PORT" "$smtpPort" "$appEnv"
  upsertEnv "SPRING_MAIL_USERNAME" "$smtpUsername" "$appEnv"
  upsertEnv "SPRING_MAIL_PASSWORD" "$smtpPassword" "$appEnv"
  upsertEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_AUTH" "true" "$appEnv"
  upsertEnv "SPRING_MAIL_PROPERTIES_MAIL_SMTP_SSL_ENABLE" "true" "$appEnv"
  upsertEnv "NOTIFICATION_EMAIL_FROM" "$emailFrom" "$appEnv"
  upsertEnv "NOTIFICATION_EMAIL_SUBJECTPREFIX" "$subjectPrefix" "$appEnv"
else
  echo "  SMTP already configured (SPRING_MAIL_HOST set) — keeping existing mail settings."
fi

# Enable email and configure the Keycloak admin client (this is what makes the email handler bean exist).
upsertEnv "FEATURES_NOTIFICATIONAPI_EMAIL_ENABLED" "true" "$appEnv"
upsertEnv "KEYCLOAK_SERVERURL" "$keycloakServerUrl" "$appEnv"
upsertEnv "KEYCLOAK_REALM" "$keycloakRealm" "$appEnv"
upsertEnv "KEYCLOAK_CLIENTID" "$keycloakClientId" "$appEnv"
upsertEnv "KEYCLOAK_CLIENTSECRET" "$keycloakClientSecret" "$appEnv"

# Ensure the app base URL is set (used for email "manage settings" + notification action links).
# Only set when empty so any custom value is preserved.
if [ -z "$(getVar "$appEnv" APPLICATION_BASEURL)" ]; then
  upsertEnv "APPLICATION_BASEURL" "https://$instance.$DOMAIN" "$appEnv"
fi

(cd "$path" && docker compose up -d)

echo "Email notifications enabled."
