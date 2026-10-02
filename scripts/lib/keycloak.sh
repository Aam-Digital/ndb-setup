#!/bin/bash
# Keycloak admin API helpers for ndb-setup scripts. Source after lib/init.sh:
#   source "$scriptDir/lib/keycloak.sh"
#
# Requires: KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD set before use (requireConfig), and jq.
# The admin token is fetched (and refreshed, it is short-lived) automatically; call getKeycloakToken once up
# front only to fail early with a clear error.
#
# Helpers that set something up print only their result (e.g. a client secret) on stdout and their progress
# on stderr, so they can be used as `secret=$(ensureKeycloakBackendClient "$org") || exit 1`.

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

##############################
# Keycloak admin API
##############################

# Obtain a Keycloak admin access token.
# Sets: token (global)
getKeycloakToken() {
  local raw
  raw=$(curl -s -L "https://$KEYCLOAK_HOST/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode username="$KEYCLOAK_USER" \
    --data-urlencode password="$KEYCLOAK_PASSWORD" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli)
  token=$(echo "$raw" | jq -r '.access_token // empty' 2>/dev/null)
  _kcTokenAt=$SECONDS

  if [ -z "$token" ]; then
    echo "ERROR: Failed to get Keycloak admin token." >&2
    return 1
  fi
}

# Get a token if there is none yet, or if it is older than 30s (admin tokens are valid for 60s by default).
_kcEnsureToken() {
  if [ -z "${token:-}" ] || [ $((SECONDS - ${_kcTokenAt:-0})) -ge 30 ]; then
    getKeycloakToken
  fi
}

# Call the Keycloak admin REST API and print the response body. Fails on an error status.
# Args: method, path below /admin/realms (e.g. "$realm/clients?clientId=app"; "" for /admin/realms itself),
#       [JSON body]
kcApi() {
  local method="$1" apiPath="$2" body="${3:-}"
  _kcEnsureToken || return 1
  local args=(-s -f -L -X "$method" -H "Authorization: Bearer $token")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" "https://$KEYCLOAK_HOST/admin/realms${apiPath:+/$apiPath}"
}

# Create something with a POST and print the id Keycloak assigned to it (the last part of the Location
# header). Fails, printing the response status on stderr, if nothing was created.
# Args: path below /admin/realms (e.g. "$realm/clients"), JSON body
kcCreate() {
  local apiPath="$1" body="$2" headers id
  _kcEnsureToken || return 1
  headers=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms${apiPath:+/$apiPath}" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$body" | tr -d '\r')
  id=$(printf '%s\n' "$headers" | sed -n 's#^[Ll]ocation:.*/##p')
  if [ -z "$id" ]; then
    echo "  Keycloak: POST /admin/realms/$apiPath -> $(printf '%s\n' "$headers" | head -n 1)" >&2
    return 1
  fi
  echo "$id"
}

# Prints the HTTP status of the realm on the central Keycloak (200 = exists, 404 = not found).
getKeycloakRealmStatus() {
  _kcEnsureToken || return 1
  curl -s -o /dev/null -w "%{http_code}" "https://$KEYCLOAK_HOST/admin/realms/$1" \
    -H "Authorization: Bearer $token"
}

# Fail unless the instance's KEYCLOAK_URL is unset or the central Keycloak (KEYCLOAK_HOST): the admin
# credentials only reach that one, and an instance must never be repointed to another Keycloak.
# Args: the instance's .env
requireCentralKeycloak() {
  local current
  current=$(getVar "$1" KEYCLOAK_URL)
  current="${current//[\"\']/}"
  if ! isPlaceholderValue "$current" && [ "$current" != "$KEYCLOAK_HOST" ]; then
    echo "ERROR: the instance uses Keycloak '$current' (KEYCLOAK_URL in .env), not '$KEYCLOAK_HOST'."
    echo "  These admin credentials cannot manage it."
    return 1
  fi
}

# Fetch a realm's active RS256 signing key (used to configure JWT auth for CouchDB / replication-backend).
# Sets: kid, publicKey (globals). Returns non-zero if the key could not be determined.
getKeycloakRealmKey() {
  local realm="$1" keys
  keys=$(kcApi GET "$realm/keys")
  kid=$(echo "$keys" | jq -r '.active.RS256 // empty' 2>/dev/null)
  publicKey=$(echo "$keys" | jq -r --arg kid "$kid" '.keys[] | select(.kid==$kid) | .publicKey // empty' 2>/dev/null)
  if [ -z "$kid" ] || [ -z "$publicKey" ]; then
    echo "ERROR: Could not determine active RS256 key for realm '$realm'." >&2
    return 1
  fi
}

# Print the internal id of a client in a realm. Fails if there is no such client. Args: realm, clientId
getKeycloakClientUuid() {
  local uuid
  uuid=$(kcApi GET "$1/clients?clientId=$2" | jq -r '.[0]?.id // empty' 2>/dev/null)
  [ -n "$uuid" ] && echo "$uuid"
}

# Print the secret of a client. Fails if it has none. Args: realm, client uuid
getKeycloakClientSecret() {
  local secret
  secret=$(kcApi GET "$1/clients/$2/client-secret" | jq -r '.value // empty' 2>/dev/null)
  [ -n "$secret" ] && echo "$secret"
}

# A confidential client with a service account and no interactive login flows. Args: clientId
_serviceAccountClientJson() {
  jq -n --arg id "$1" '{
    clientId: $id,
    enabled: true,
    clientAuthenticatorType: "client-secret",
    serviceAccountsEnabled: true,
    publicClient: false,
    standardFlowEnabled: false,
    directAccessGrantsEnabled: false,
    protocol: "openid-connect"
  }'
}

# Print the uuid of a service-account client, creating the client if it does not exist yet.
# Args: realm, clientId
_ensureServiceAccountClient() {
  local realm="$1" clientId="$2" uuid
  if uuid=$(getKeycloakClientUuid "$realm" "$clientId"); then
    echo "  $clientId client already exists in realm '$realm': $uuid" >&2
  elif uuid=$(kcCreate "$realm/clients" "$(_serviceAccountClientJson "$clientId")"); then
    echo "  Created $clientId client in realm '$realm': $uuid" >&2
  else
    echo "  ERROR: Failed to create the $clientId client in realm '$realm'." >&2
    return 1
  fi
  echo "$uuid"
}

##############################
# aam-backend client (the backend's and replication-backend's Keycloak admin access)
##############################

# realm-management roles the aam-backend service account needs
# (manage-clients: aam-backend-service creates and assigns the client scopes its API endpoints check)
AAM_BACKEND_REALM_MANAGEMENT_ROLES=("manage-realm" "manage-clients" "query-users" "view-users" "manage-users")

# Ensure the realm's aam-backend client exists and its service account holds
# AAM_BACKEND_REALM_MANAGEMENT_ROLES (checked afterwards), plus the "roles" client scope. Idempotent.
# Prints the client secret. Fails if the client, its secret or the roles could not be set up.
# Args: realm
ensureKeycloakBackendClient() {
  local realm="$1" uuid secret
  uuid=$(_ensureServiceAccountClient "$realm" aam-backend) || return 1
  if ! secret=$(getKeycloakClientSecret "$realm" "$uuid"); then
    echo "  ERROR: Failed to get the secret of the aam-backend client in realm '$realm'." >&2
    return 1
  fi
  _assignBackendRealmManagementRoles "$realm" "$uuid" >&2 || return 1
  if ! serviceAccountHasRealmManagementRole "$realm" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "  ERROR: Could not confirm the realm-management roles (${AAM_BACKEND_REALM_MANAGEMENT_ROLES[*]}) on the aam-backend service account in realm '$realm'." >&2
    return 1
  fi
  echo "$secret"
}

# Returns 0 if the aam-backend service account has all the given (effective) realm-management roles, else 1.
# Args: realm, roleName...
serviceAccountHasRealmManagementRole() {
  local realm="$1"
  shift
  local clientUuid userId mgmtUuid effectiveRoles roleName
  clientUuid=$(getKeycloakClientUuid "$realm" aam-backend) || return 1
  userId=$(kcApi GET "$realm/clients/$clientUuid/service-account-user" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$userId" ] || return 1
  mgmtUuid=$(getKeycloakClientUuid "$realm" realm-management) || return 1
  # effective (composite) role mappings, so manage-users (which contains view-users) also counts
  effectiveRoles=$(kcApi GET "$realm/users/$userId/role-mappings/clients/$mgmtUuid/composite") || return 1
  for roleName in "$@"; do
    echo "$effectiveRoles" | jq -e --arg r "$roleName" 'any(.[]; .name == $r)' >/dev/null 2>&1 || return 1
  done
}

# Prints the client secret of the aam-backend client in the realm. Fails if the client does not exist.
# Args: realm
getKeycloakBackendClientSecret() {
  local uuid
  uuid=$(getKeycloakClientUuid "$1" aam-backend) || return 1
  getKeycloakClientSecret "$1" "$uuid"
}

# Configure aam-backend-service's Keycloak admin access (KEYCLOAK_* in application.env) with the aam-backend
# client. The backend uses it to provision the client scopes its API checks and to look up user emails.
# An existing server URL is kept; realm, client ID and secret are always set, so they match each other.
# Args: appEnvFile, serverUrl (e.g. https://keycloak.example.com), realm, clientSecret
ensureBackendKeycloakAdminConfig() {
  local appEnvFile="$1" serverUrl="$2" realm="$3" clientSecret="$4"
  ensureRealValue "KEYCLOAK_SERVERURL" "$serverUrl" "$appEnvFile" || return 1
  upsertEnv "KEYCLOAK_REALM" "$realm" "$appEnvFile" || return 1
  upsertEnv "KEYCLOAK_CLIENTID" "aam-backend" "$appEnvFile" || return 1
  upsertEnv "KEYCLOAK_CLIENTSECRET" "$clientSecret" "$appEnvFile" || return 1
}

# Assign AAM_BACKEND_REALM_MANAGEMENT_ROLES and the "roles" client scope (for role claims in the access token)
# to a client's service account. Args: realm, client uuid
_assignBackendRealmManagementRoles() {
  local realm="$1" clientUuid="$2" userId mgmtUuid
  userId=$(kcApi GET "$realm/clients/$clientUuid/service-account-user" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$userId" ]; then
    echo "  ERROR: Could not get the service account user of the aam-backend client in realm '$realm'."
    return 1
  fi
  if ! mgmtUuid=$(getKeycloakClientUuid "$realm" realm-management); then
    echo "  ERROR: Could not find the realm-management client in realm '$realm'."
    return 1
  fi

  local rolePayload="[]" roleName roleJson
  for roleName in "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; do
    if roleJson=$(kcApi GET "$realm/clients/$mgmtUuid/roles/$roleName"); then
      rolePayload=$(echo "$rolePayload" | jq --argjson role "$roleJson" '. + [$role]')
    else
      echo "  WARNING: Could not resolve realm-management role '$roleName' in realm '$realm'."
    fi
  done
  if ! kcApi POST "$realm/users/$userId/role-mappings/clients/$mgmtUuid" "$rolePayload" >/dev/null; then
    echo "  ERROR: Failed to assign realm-management roles to the aam-backend service account in realm '$realm'."
    return 1
  fi
  echo "  Ensured realm-management roles on the aam-backend service account: ${AAM_BACKEND_REALM_MANAGEMENT_ROLES[*]}."

  local rolesScopeUuid
  rolesScopeUuid=$(kcApi GET "$realm/client-scopes" | jq -r '.[] | select(.name == "roles") | .id // empty' 2>/dev/null)
  if [ -n "$rolesScopeUuid" ] \
    && kcApi PUT "$realm/clients/$clientUuid/default-client-scopes/$rolesScopeUuid" >/dev/null; then
    echo "  Ensured 'roles' client scope on the aam-backend client."
  else
    echo "  WARNING: Could not assign the 'roles' client scope in realm '$realm'."
  fi
}

##############################
# Carbone render client helpers
##############################

# CARBONE_REALM is the central realm for Carbone PDF render API access
CARBONE_REALM="aam-platform"

# oauth2-proxy client ID — render clients must include this in their token audience.
OAUTH2_PROXY_CLIENT_ID="carbone-oauth2-proxy"

# Ensure a render client in the central aam-platform realm, with an audience mapper that puts
# OAUTH2_PROXY_CLIENT_ID in its access tokens (oauth2-proxy rejects tokens without it). Idempotent.
# Prints the client secret. Args: realm, clientId
ensureCarboneRenderClient() {
  local realm="$1" clientId="$2" uuid secret
  uuid=$(_ensureServiceAccountClient "$realm" "$clientId") || return 1
  if ! secret=$(getKeycloakClientSecret "$realm" "$uuid"); then
    echo "  ERROR: Failed to get the secret of the $clientId client in realm '$realm'." >&2
    return 1
  fi
  _ensureAudienceMapper "$realm" "$uuid" >&2 || return 1
  echo "$secret"
}

# Ensure the audience mapper for OAUTH2_PROXY_CLIENT_ID on a client (checked by mapper name).
# Args: realm, client uuid
_ensureAudienceMapper() {
  local realm="$1" clientUuid="$2" mapperName="audience-${OAUTH2_PROXY_CLIENT_ID}" mappers
  if ! mappers=$(kcApi GET "$realm/clients/$clientUuid/protocol-mappers/models"); then
    echo "  ERROR: could not read the protocol mappers of the client."
    return 1
  fi
  if echo "$mappers" | jq -e --arg n "$mapperName" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
    echo "  audience mapper already present on client."
    return 0
  fi

  local mapper
  mapper=$(jq -n --arg name "$mapperName" --arg audience "$OAUTH2_PROXY_CLIENT_ID" '{
    name: $name,
    protocol: "openid-connect",
    protocolMapper: "oidc-audience-mapper",
    config: {
      "included.client.audience": $audience,
      "id.token.claim": "false",
      "access.token.claim": "true",
      "introspection.token.claim": "true",
      "userinfo.token.claim": "false"
    }
  }')
  if ! kcApi POST "$realm/clients/$clientUuid/protocol-mappers/models" "$mapper" >/dev/null; then
    echo "  ERROR: failed to add the audience mapper."
    return 1
  fi
  echo "  Added audience mapper for $OAUTH2_PROXY_CLIENT_ID."
}

##############################
# account_manager realm role
##############################

# realm-management roles the "account_manager" realm role must grant its members.
# manage-realm is what lets the app's "Roles & Permissions" admin UI create and delete realm roles;
# Keycloak has no narrower built-in role for that.
ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES=("view-realm" "manage-users" "manage-realm")

# Print the ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES that "account_manager" does not grant yet (space-separated,
# nothing if none). Fails if its roles cannot be read. Args: realm, realm-management client uuid
_accountManagerMissingRoles() {
  local composites
  composites=$(kcApi GET "$1/roles/account_manager/composites/clients/$2") || return 1
  echo "$composites" | jq -r --arg want "${ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES[*]}" \
    'if type == "array" then ($want | split(" ")) - [.[].name] | join(" ") else error("not a list") end' 2>/dev/null
}

# Add the ACCOUNT_MANAGER_REALM_MANAGEMENT_ROLES that the "account_manager" realm role does not grant yet, and
# check afterwards that it grants all of them. Prints nothing when nothing is missing. Args: realm
ensureAccountManagerRealmManagementRoles() {
  local realm="$1" mgmtUuid missing
  if ! mgmtUuid=$(getKeycloakClientUuid "$realm" realm-management); then
    echo "  ERROR: Could not find the realm-management client in realm '$realm'."
    return 1
  fi
  if ! missing=$(_accountManagerMissingRoles "$realm" "$mgmtUuid"); then
    echo "  ERROR: Could not read the roles of 'account_manager' in realm '$realm' (does the realm have it?)."
    return 1
  fi
  [ -n "$missing" ] || return 0

  echo "Adding the realm-management roles of 'account_manager': $missing"
  local rolePayload="[]" roleName roleJson
  for roleName in $missing; do
    if ! roleJson=$(kcApi GET "$realm/clients/$mgmtUuid/roles/$roleName"); then
      echo "  ERROR: Could not resolve realm-management role '$roleName' in realm '$realm'."
      return 1
    fi
    rolePayload=$(echo "$rolePayload" | jq --argjson role "$roleJson" '. + [$role]')
  done
  if ! kcApi POST "$realm/roles/account_manager/composites" "$rolePayload" >/dev/null \
    || [ -n "$(_accountManagerMissingRoles "$realm" "$mgmtUuid")" ]; then
    echo "  ERROR: Could not add the realm-management roles to 'account_manager' in realm '$realm'."
    return 1
  fi
  echo "  Added. Users with the account_manager role need to log out and back in."
}

##############################
# exact_username User Profile attribute
##############################

# The `exact_username` User Profile attribute (the entity id linked to a user account): view-able by
# admin+user, but edit-able by admins only - a user changing their own linked id would be a
# permission-escalation loophole. Fresh realms get it from realm_config.json; realms upgraded in place to
# Keycloak 26 lose it, since custom User Profile attributes are outside Keycloak's automatic migration.
EXACT_USERNAME_ATTR='{
  "name": "exact_username",
  "displayName": "Aam Digital user profile ID",
  "permissions": { "view": ["admin","user"], "edit": ["admin"] },
  "multivalued": false
}'

# Declare EXACT_USERNAME_ATTR in the realm's User Profile if missing (idempotent; existing attributes and
# values are preserved).
# Args: realm
# Returns: 1 if the profile could not be read or written.
ensureExactUsernameUserProfileAttribute() {
  local realm="$1" profile
  profile=$(kcApi GET "$realm/users/profile")
  if ! echo "$profile" | jq -e '.attributes' >/dev/null 2>&1; then
    echo "  ERROR: could not read the User Profile of realm '$realm', not checking exact_username."
    return 1
  fi
  if echo "$profile" | jq -e 'any(.attributes[]?; .name == "exact_username")' >/dev/null 2>&1; then
    return 0
  fi

  if ! kcApi PUT "$realm/users/profile" "$(echo "$profile" | jq --argjson a "$EXACT_USERNAME_ATTR" '.attributes += [$a]')" >/dev/null; then
    echo "  ERROR: adding exact_username to the User Profile of realm '$realm' failed."
    return 1
  fi
  echo "  ~ added exact_username to the User Profile of realm '$realm'"
}
