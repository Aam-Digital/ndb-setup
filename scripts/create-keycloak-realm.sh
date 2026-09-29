#!/bin/bash

# Create (or reuse) the Keycloak realm and the "app" client for an instance, and persist the
# realm's signing key into the instance .env for CouchDB / replication-backend JWT auth.
# (The app container generates its own keycloak.json at start from KEYCLOAK_URL/KEYCLOAK_REALM -
# see docker-compose.yml - so this script no longer needs to download and write that file itself.)
# Idempotent: an existing realm or client is reused; the key values are written when missing or changed.
#
# Re-running it on an existing instance repairs its realm to what the realm template sets up:
#   - the realm-management roles of the "account_manager" realm role (view-realm, manage-users,
#     manage-realm), needed by the app's "Roles & Permissions" admin UI - users need to log out and back in
#   - the admin-only `exact_username` User Profile attribute, which realms upgraded in place to Keycloak 26
#     lose (see keycloak/README.md)
# For all instances: ./for-each-instance.sh ./create-keycloak-realm.sh
#
# Usage:
#   ./create-keycloak-realm.sh <instance> [locale] [baseConfig]
#
# <instance>  an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the instance
#             directory (e.g. "." when run from inside it). The realm name is read from the .env INSTANCE_NAME.
# [locale]    default language, only used (and asked for) when the realm is created
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD; SMTP_SERVER, SMTP_PASSWORD (only to create the realm)

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"

##############################
# input
##############################

requireInstance "${1:-}"
# the realm is named after INSTANCE_NAME, don't guess it from the folder name
if [ -z "$(getVar "$path/.env" INSTANCE_NAME)" ]; then
  echo "ERROR: INSTANCE_NAME not set in $path/.env. Abort."
  exit 1
fi
url=$org.$DOMAIN

locale="${2:-}"
baseConfig="${3:-}"

requireConfig KEYCLOAK_HOST
requireConfig KEYCLOAK_USER
requireConfig KEYCLOAK_PASSWORD

# The admin credentials only reach the central Keycloak: never repoint an instance using another one.
instanceKeycloakHost=$(getVar "$path/.env" KEYCLOAK_URL)
if ! isPlaceholderValue "$instanceKeycloakHost" && [ "$instanceKeycloakHost" != "$KEYCLOAK_HOST" ]; then
  echo "ERROR: '$org' uses Keycloak '$instanceKeycloakHost' (KEYCLOAK_URL in .env), not '$KEYCLOAK_HOST'. Abort."
  exit 1
fi

##############################
# script
##############################

[ "$instanceKeycloakHost" == "$KEYCLOAK_HOST" ] || setEnv KEYCLOAK_URL "$KEYCLOAK_HOST" "$path/.env"

if ! getKeycloakToken; then
  echo "ERROR: could not authenticate against Keycloak. Abort."
  exit 1
fi

# Whether this instance was already set up against a realm. KEYCLOAK_JWT_KID is only in .env since mid-2026,
# so older instances are recognised by their public key or their CouchDB data.
instanceWasSetUp() {
  ! isPlaceholderValue "$(getVar "$path/.env" KEYCLOAK_JWT_KID)" \
    || ! isPlaceholderValue "$(getVar "$path/.env" REPLICATION_BACKEND_PUBLIC_KEY)" \
    || [ -n "$(ls -A "$path/couchdb/data" 2>/dev/null)" ]
}

# create the realm (idempotent: skip if it already exists). Only a 404 means "missing": a timeout or an
# error status must not lead to creating a realm.
realmStatus=$(getKeycloakRealmStatus "$org")
if [ "$realmStatus" = "200" ]; then
  echo "Keycloak realm '$org' already exists, skipping creation."
elif [ "$realmStatus" != "404" ]; then
  echo "ERROR: could not check Keycloak realm '$org' (HTTP $realmStatus). Abort."
  exit 1
elif instanceWasSetUp; then
  # a fresh, empty realm would lock out every user
  echo "ERROR: Keycloak realm '$org' not found, but this instance was already set up with a realm"
  echo "  (KEYCLOAK_JWT_KID / REPLICATION_BACKEND_PUBLIC_KEY in .env, or CouchDB data). Not creating a new,"
  echo "  empty realm. Check that INSTANCE_NAME matches the realm name. Abort."
  exit 1
else
  echo "Creating Keycloak realm '$org'..."
  if [ -z "$locale" ]; then
    echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
    read -r locale
  fi
  requireConfig SMTP_SERVER
  requireConfig SMTP_PASSWORD

  # take the custom baseConfig realm file or otherwise the default from keycloak folder
  keycloakRealmFile="$ndbSetupDir/keycloak/realm_config.json"
  if [ -n "$baseConfig" ] && [ -f "$ndbSetupDir/baseConfigs/$baseConfig/realm_config.json" ]; then
    keycloakRealmFile="$ndbSetupDir/baseConfigs/$baseConfig/realm_config.json"
  fi
  # add and replace some customized values
  keycloakRealmJson=$(jq \
    --arg realm "$org" \
    --arg locale "$locale" \
    --arg host "$SMTP_SERVER" \
    --arg password "$SMTP_PASSWORD" \
    '.realm = $realm
     | .defaultLocale = $locale
     | .displayName = "Aam Digital - " + $realm
     | .smtpServer.from = "accounts@aam-digital.com"
     | .smtpServer.host = $host
     | .smtpServer.port = "587"
     | .smtpServer.user = "accounts@aam-digital.com"
     | .smtpServer.password = $password' \
    "$keycloakRealmFile")

  createStatus=$(curl -s -o /dev/null -w "%{http_code}" -X "POST" "https://$KEYCLOAK_HOST/admin/realms" \
       -H "Authorization: Bearer $token" \
       -H "Content-Type: application/json" \
       -d "$keycloakRealmJson")
  if [ "$createStatus" != "201" ]; then
    echo "ERROR: failed to create Keycloak realm '$org' (HTTP $createStatus). Abort."
    exit 1
  fi
fi

# create the "app" client (idempotent: reuse existing)
client=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/clients?clientId=app" \
  -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
if [ -n "$client" ]; then
  echo "Keycloak 'app' client already exists ($client), skipping creation."
else
  echo "Creating Keycloak 'app' client..."
  clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$org/clients" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$(jq --arg url "https://$url" '.baseUrl = $url' "$ndbSetupDir/keycloak/client_config.json")")
  location=$(echo "$clientResponse" | grep -i "^location:")
  client=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')
  if [ -z "$client" ]; then
    echo "ERROR: failed to create Keycloak 'app' client. Abort."
    exit 1
  fi
fi

# persist the realm signing key so create-couchdb.sh can configure JWT auth without any Keycloak access
if ! getKeycloakRealmKey "$org"; then
  echo "ERROR: could not read realm signing key. Abort."
  exit 1
fi
# also adds them to instances set up before they were kept in .env
[ "$(getVar "$path/.env" REPLICATION_BACKEND_PUBLIC_KEY)" == "$publicKey" ] || upsertEnv REPLICATION_BACKEND_PUBLIC_KEY "$publicKey" "$path/.env"
[ "$(getVar "$path/.env" KEYCLOAK_JWT_KID)" == "$kid" ] || upsertEnv KEYCLOAK_JWT_KID "$kid" "$path/.env"

# Repairs for realms created from an older realm template (fresh realms already have both).
repairFailed=false
if ! accountManagerHasRealmManagementRoles "$org" "${ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES[@]}"; then
  echo "Adding the realm-management roles of 'account_manager'..."
  if ensureAccountManagerRealmManagementRoles "$org" \
    && accountManagerHasRealmManagementRoles "$org" "${ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "  Users with the account_manager role need to log out and back in."
  else
    echo "  ERROR: Could not confirm the realm-management roles on 'account_manager'."
    repairFailed=true
  fi
fi
ensureExactUsernameUserProfileAttribute "$org" || repairFailed=true

if [ "$repairFailed" = true ]; then
  echo "Keycloak realm '$org' is configured, but a repair failed (see above)."
  exit 1
fi
echo "Keycloak realm '$org' is configured."
