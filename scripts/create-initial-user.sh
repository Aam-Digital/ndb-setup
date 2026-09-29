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

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"
source "$scriptDir/lib/couchdb.sh"

##############################
# input
##############################

requireInstance "${1:-}"
# the realm is named after INSTANCE_NAME, don't guess it from the folder name
if [ -z "$(getVar "$path/.env" INSTANCE_NAME)" ]; then
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

userId=$(kcApi GET "$org/users?exact=true&username=$(jq -rn --arg v "$userName" '$v|@uri')" | jq -r '.[0].id // empty')
userCreated=false
if [ -n "$userId" ]; then
  echo "Keycloak user '$userName' already exists ($userId), reusing."
else
  echo "Creating Keycloak user '$userName'..."
  newUserPayload=$(jq -n --arg username "$userName" --arg email "$userEmail" --arg exactUsername "User:$userName" \
    '{username: $username, enabled: true, email: $email, attributes: {exact_username: [$exactUsername]}, emailVerified: false, credentials: [], requiredActions: ["UPDATE_PASSWORD", "VERIFY_EMAIL"]}')
  userId=$(kcCreate "$org/users" "$newUserPayload")
  userCreated=true
fi

if [ -z "$userId" ]; then
  echo "ERROR: could not resolve Keycloak user id for '$userName'. Abort."
  exit 1
fi
echo "User id $userId"

# assign all realm roles (idempotent — Keycloak ignores already-assigned roles)
echo "assign realm roles..."
roles=$(kcApi GET "$org/roles")
kcApi POST "$org/users/$userId/role-mappings/realm" "$roles" >/dev/null || echo "  WARNING: assigning the realm roles failed."

# enable email 2FA by removing the "no-email-2fa" role (idempotent — removing an absent mapping is harmless)
echo "enable 2fa for user..."
roleId=$(echo "$roles" | jq -r '.[] | select(.name=="no-email-2fa") | .id')
if [ -z "$roleId" ]; then
  echo "  WARNING: no 'no-email-2fa' role found."
else
  kcApi DELETE "$org/users/$userId/role-mappings/realm" "[{\"id\": \"$roleId\"}]" >/dev/null \
    || echo "  WARNING: removing the 'no-email-2fa' role failed."
fi

# send the verification email only for a freshly-created user, so re-runs do not re-send onboarding mail
if [ "$userCreated" = true ]; then
  echo "send verification email..."
  # no redirect_uri: Keycloak falls back to the "app" client's baseUrl for the "back to application" link
  kcApi PUT "$org/users/$userId/execute-actions-email?client_id=app" '["VERIFY_EMAIL"]' >/dev/null \
    || echo "  WARNING: sending the verification email failed."
fi

##############################
# CouchDB user document
##############################

userDocId="User:$userName"
encodedUserDocId=$(jq -rn --arg v "$userDocId" '$v|@uri')

echo "ensure user document in CouchDB..."
couchdbInitStart || exit 1
if [ "$(couchdbCurl -o /dev/null -w '%{http_code}' "$DB_LOCAL_URL/app/$encodedUserDocId")" = "200" ]; then
  echo "  = $userDocId document already exists, keeping it"
else
  userDocPayload=$(jq -n --arg name "$userName" '{name: $name}')
  couchdbCurl -X PUT -H 'Content-Type: application/json' -d "$userDocPayload" \
    "$DB_LOCAL_URL/app/$encodedUserDocId" >/dev/null
  echo "  + created $userDocId document"
fi
couchdbInitStop

echo "Initial user '$userName' is set up for '$org'."
