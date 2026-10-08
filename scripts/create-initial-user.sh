#!/bin/bash
usage() {
  cat <<'EOF'
Create the initial admin user of an instance in Keycloak (with all realm roles, email 2FA and a verification
email). The app creates and links the user's User entity itself on first startup.

Usage:
  ./create-initial-user.sh <instance> [email] [--skip-restart]

Asks for the email if it is not given. The email is also used as the Keycloak username. A third argument (the
former user name) is still accepted and ignored.

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD

Safe to re-run: an existing Keycloak user with that email is reused, and the verification email is only sent
when the Keycloak user is created.
EOF
  exit "${1:-1}"
}

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"
# --skip-restart is accepted (and ignored: this script changes no running service), stripped from
# "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

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
if [ -z "$userEmail" ]; then
  echo "ERROR: an email address is required. Abort."
  exit 1
fi
# Keycloak stores usernames lowercased
userName=$(echo "$userEmail" | tr '[:upper:]' '[:lower:]')

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

# look up by email, so a user created earlier with a different username is reused as well
userId=$(kcApi GET "$org/users?exact=true&email=$(jq -rn --arg v "$userEmail" '$v|@uri')" | jq -r '.[0].id // empty')
userCreated=false
if [ -n "$userId" ]; then
  echo "Keycloak user with email '$userEmail' already exists ($userId), reusing."
else
  echo "Creating Keycloak user '$userName'..."
  newUserPayload=$(jq -n --arg username "$userName" --arg email "$userEmail" \
    '{username: $username, enabled: true, email: $email, emailVerified: false, credentials: [], requiredActions: ["UPDATE_PASSWORD", "VERIFY_EMAIL"]}')
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

echo "Initial user '$userName' is set up for '$org'."
