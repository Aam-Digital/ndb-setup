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

# Derive the Keycloak admin client config required for the email handler. The handler uses Keycloak to
# resolve recipient email addresses, reusing the aam-backend service-account client created by
# enable-backend.sh. That service account must hold the realm-management "view-users" role; instances
# provisioned before that role was added fail recipient lookups with HTTP 403 Forbidden.
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

# Resolve Keycloak admin credentials (needed to assign AND verify the realm-management roles). Prefer
# values from setup.env, otherwise load from BWS. Without them we can neither patch nor verify the role.
if [[ -z "${KEYCLOAK_HOST:-}" || -z "${KEYCLOAK_USER:-}" || -z "${KEYCLOAK_PASSWORD:-}" ]] && [[ -n "${BWS_ACCESS_TOKEN:-}" ]]; then
  echo "Loading Keycloak admin credentials from Bitwarden Secrets Manager..."
  bws config server-base https://vault.bitwarden.eu
  KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
  KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
  KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)
fi

adminCredsAvailable=false
roleAlreadyPresent=false
if [[ -n "${KEYCLOAK_HOST:-}" && -n "${KEYCLOAK_USER:-}" && -n "${KEYCLOAK_PASSWORD:-}" ]]; then
  adminCredsAvailable=true
  source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"
  if serviceAccountHasRealmManagementRole "$instance" "view-users"; then
    roleAlreadyPresent=true
  fi
fi

# Idempotent fast path: fully configured AND the role is already present -> nothing to do.
if [ "$isEmailAlreadyEnabled" == "true" ] && [ -n "$existingKeycloakServerUrl" ] && [ "$roleAlreadyPresent" == "true" ]; then
  echo "Email notifications already fully configured for instance '$instance' (incl. view-users role). Nothing to do."
  exit 0
fi

# Config is already complete but we cannot reach Keycloak to verify/patch the role -> nothing more to write.
if [ "$isEmailAlreadyEnabled" == "true" ] && [ -n "$existingKeycloakServerUrl" ] && [ "$adminCredsAvailable" != "true" ]; then
  echo "Email is configured for instance '$instance', but Keycloak admin credentials are unavailable, so the"
  echo "'view-users' role on the aam-backend service account could not be verified or repaired."
  echo "If recipient lookups fail with 'HTTP 403 Forbidden', re-run with KEYCLOAK_HOST/USER/PASSWORD in setup.env"
  echo "(or a BWS_ACCESS_TOKEN that can read the Keycloak secrets)."
  exit 0
fi

echo ""
if [ "$isEmailAlreadyEnabled" == "true" ]; then
  echo "Email is enabled but needs repair (missing Keycloak admin config and/or 'view-users' role) — repairing '$instance'..."
else
  echo "Configuring email notifications for '$instance'..."
fi

# Best-effort: (re)assign the realm-management roles on the aam-backend service account (idempotent —
# patches old clients missing "view-users") and capture the authoritative client secret. This MUST NOT
# hard-fail enabling email: if Keycloak is unreachable we keep going with the secret from .env and warn
# loudly, because a lingering 403 is otherwise silent.
keycloakRolesEnsured=false
if [ "$adminCredsAvailable" == "true" ]; then
  if createKeycloakBackendClient "$instance" && [ -n "$clientSecret" ]; then
    keycloakClientSecret="$clientSecret"
    # keep .env in sync — the replication-backend uses the same client
    if grep -q '^REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=' "$path/.env"; then
      setEnv "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET" "$clientSecret" "$path/.env"
    fi
  else
    echo "  WARNING: Could not create/fetch the aam-backend Keycloak client; using the secret from .env."
  fi
  # Verify the role actually stuck — createKeycloakBackendClient returns 0 even if assignment only warned.
  if serviceAccountHasRealmManagementRole "$instance" "view-users"; then
    keycloakRolesEnsured=true
    echo "  Verified: aam-backend service account has the realm-management 'view-users' role."
  else
    echo "  WARNING: Could not confirm the 'view-users' role on the aam-backend service account."
  fi
else
  echo "  WARNING: Keycloak admin credentials unavailable (set KEYCLOAK_HOST/USER/PASSWORD in setup.env, or BWS_ACCESS_TOKEN)."
  echo "           Skipping realm-management role assignment/verification — recipient lookups may fail with HTTP 403."
fi

if [ -z "$keycloakClientSecret" ]; then
  echo "ERROR: No aam-backend Keycloak client secret available (REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET missing"
  echo "       in $path/.env and not retrievable from Keycloak). Run './enable-backend.sh $instance' first."
  exit 1
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

if [ "$keycloakRolesEnsured" == "true" ]; then
  echo "Email notifications enabled."
else
  echo ""
  echo "Email notifications configured, BUT the aam-backend service account's realm-management 'view-users'"
  echo "role could NOT be confirmed. Recipient email lookups may fail with 'HTTP 403 Forbidden'."
  echo "Re-run this script with Keycloak admin access (KEYCLOAK_HOST/USER/PASSWORD in setup.env, or a"
  echo "BWS_ACCESS_TOKEN that can read the Keycloak secrets) to assign and verify the role."
fi
