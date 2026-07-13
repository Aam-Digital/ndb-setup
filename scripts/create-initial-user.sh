#!/bin/bash

# Create the initial admin user for an instance, in Keycloak (with all realm roles, email 2FA, and a
# verification email) and as a User document in CouchDB.
# Idempotent: an existing Keycloak user or CouchDB document is reused; the verification email is only
# sent when the Keycloak user is newly created, so re-running never re-sends onboarding mail.
#
# Usage:
#   ./create-initial-user.sh <instance> <email> <name>
#
# <instance>  an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the instance
#             directory (e.g. "." when run from inside it). The realm name is read from the .env INSTANCE_NAME.
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD

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
source "$scriptDir/lib/couchdb.sh"

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

if [ -n "$2" ]; then
  userEmail="$2"
else
  echo "Email address of initial user"
  read -r userEmail
fi
if [ -n "$3" ]; then
  userName="$3"
else
  echo "Name of initial user"
  read -r userName
fi
if [ -z "$userEmail" ] || [ -z "$userName" ]; then
  echo "ERROR: both email and name are required. Abort."
  exit 1
fi

requireConfig KEYCLOAK_HOST
requireConfig KEYCLOAK_USER
requireConfig KEYCLOAK_PASSWORD

##############################
# Keycloak user
##############################

if ! getKeycloakToken; then
  echo "ERROR: could not authenticate against Keycloak. Abort."
  exit 1
fi

userId=$(curl -s -H "Authorization: Bearer $token" \
  "https://$KEYCLOAK_HOST/admin/realms/$org/users?username=$userName&exact=true" | jq -r '.[0].id // empty')

userCreated=false
if [ -n "$userId" ]; then
  echo "Keycloak user '$userName' already exists ($userId), reusing."
else
  echo "Creating Keycloak user '$userName'..."
  curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "{\"username\": \"$userName\",\"enabled\": true,\"email\": \"$userEmail\",\"attributes\": {\"exact_username\": \"User:$userName\"},\"emailVerified\": false,\"credentials\": [], \"requiredActions\": [\"UPDATE_PASSWORD\", \"VERIFY_EMAIL\"]}" \
    "https://$KEYCLOAK_HOST/admin/realms/$org/users"
  userId=$(curl -s -H "Authorization: Bearer $token" \
    "https://$KEYCLOAK_HOST/admin/realms/$org/users?username=$userName&exact=true" | jq -r '.[0].id // empty')
  userCreated=true
fi

if [ -z "$userId" ]; then
  echo "ERROR: could not resolve Keycloak user id for '$userName'. Abort."
  exit 1
fi
echo "User id $userId"

# assign all realm roles (idempotent — Keycloak ignores already-assigned roles)
roles=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_HOST/admin/realms/$org/roles")
echo "assign realm roles..."
curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$roles" \
  "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/role-mappings/realm" >/dev/null

# enable email 2FA by removing the "no-email-2fa" role (idempotent — removing an absent mapping is harmless)
echo "enable 2fa for user..."
roleId=$(curl -s -X GET "https://$KEYCLOAK_HOST/admin/realms/$org/roles" -H "Authorization: Bearer $token" \
  | jq -r '.[] | select(.name=="no-email-2fa") | .id')
if [ -z "$roleId" ]; then
  echo "  WARNING: no 'no-email-2fa' role found."
else
  curl -s -X DELETE "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/role-mappings/realm" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "[{\"id\": \"$roleId\"}]" >/dev/null
fi

# send the verification email only for a freshly-created user, so re-runs do not re-send onboarding mail
if [ "$userCreated" = true ]; then
  echo "send verification email..."
  # no redirect_uri: Keycloak falls back to the "app" client's baseUrl for the "back to application" link
  curl -s -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '["VERIFY_EMAIL"]' \
    "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/execute-actions-email?client_id=app" >/dev/null
fi

##############################
# CouchDB user document
##############################

echo "ensure user document in CouchDB..."
couchdbInitStart
if [ "$(couchdbCurl -o /dev/null -w '%{http_code}' "$DB_LOCAL_URL/app/User:$userName")" = "200" ]; then
  echo "  = User:$userName document already exists, keeping it"
else
  couchdbCurl -X PUT -H 'Content-Type: application/json' -d "{\"name\": \"$userName\"}" \
    "$DB_LOCAL_URL/app/User:$userName" >/dev/null
  echo "  + created User:$userName document"
fi
couchdbInitStop

echo "Initial user '$userName' is set up for '$org'."
