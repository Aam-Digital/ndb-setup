#!/bin/bash

# Create (or reuse) the Keycloak realm and the "app" client for an instance, download keycloak.json,
# and persist the realm's signing key into the instance .env for CouchDB / replication-backend JWT auth.
# Idempotent: an existing realm or client is reused; keycloak.json and the key values are (re)written each run.
#
# Usage:
#   ./create-keycloak-realm.sh <instance> [locale] [baseConfig]
#
# <instance>  an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the instance
#             directory (e.g. "." when run from inside it). The realm name is read from the .env INSTANCE_NAME.
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD, SMTP_SERVER, SMTP_PASSWORD

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"
source "$scriptDir/lib/keycloak.sh"

##############################
# input
##############################

if [ -n "$1" ]; then
  instanceArg="$1"
else
  echo "Which instance? (name, or path to the instance directory, e.g. '.')"
  read -r instanceArg
fi
resolveInstancePath "$instanceArg" || exit 1
if [ ! -d "$path" ]; then
  echo "ERROR: instance directory not found: $path (run create-instance.sh first). Abort."
  exit 1
fi
org=$(getVar "$path/.env" INSTANCE_NAME)
if [ -z "$org" ]; then
  echo "ERROR: INSTANCE_NAME not set in $path/.env. Abort."
  exit 1
fi
url=$org.$DOMAIN

if [ -n "$2" ]; then
  locale="$2"
else
  echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
  read -r locale
fi

baseConfig="${3:-}"

requireConfig KEYCLOAK_HOST
requireConfig KEYCLOAK_USER
requireConfig KEYCLOAK_PASSWORD
requireConfig SMTP_SERVER
requireConfig SMTP_PASSWORD

##############################
# script
##############################

setEnv KEYCLOAK_URL "$KEYCLOAK_HOST" "$path/.env"

if ! getKeycloakToken; then
  echo "ERROR: could not authenticate against Keycloak. Abort."
  exit 1
fi

# create the realm (idempotent: skip if it already exists)
realmStatus=$(curl -s -o /dev/null -w "%{http_code}" -L "https://$KEYCLOAK_HOST/admin/realms/$org" \
  -H "Authorization: Bearer $token")
if [ "$realmStatus" = "200" ]; then
  echo "Keycloak realm '$org' already exists, skipping creation."
else
  echo "Creating Keycloak realm '$org'..."
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

  curl -X "POST" "https://$KEYCLOAK_HOST/admin/realms" \
       -H "Authorization: Bearer $token" \
       -H "Content-Type: application/json" \
       -d "$keycloakRealmJson"
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
    -d "$(jq '.baseUrl = "https://'"$url"'"' "$ndbSetupDir/keycloak/client_config.json")")
  location=$(echo "$clientResponse" | grep -i "^location:")
  client=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')
  if [ -z "$client" ]; then
    echo "ERROR: failed to create Keycloak 'app' client. Abort."
    exit 1
  fi
fi

# download the app's keycloak.json (frontend adapter config)
curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" \
  -H "Authorization: Bearer $token" > "$path/keycloak.json"

# persist the realm signing key so create-couchdb.sh can configure JWT auth without any Keycloak access
if ! getKeycloakRealmKey "$org"; then
  echo "ERROR: could not read realm signing key. Abort."
  exit 1
fi
upsertEnv REPLICATION_BACKEND_PUBLIC_KEY "$publicKey" "$path/.env"
upsertEnv KEYCLOAK_JWT_KID "$kid" "$path/.env"

echo "Keycloak realm '$org' is configured."
