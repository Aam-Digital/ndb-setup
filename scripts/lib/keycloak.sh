#!/bin/bash
# Keycloak admin API helpers for ndb-setup scripts.
# Source this file in any script that needs Keycloak operations:
#   source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"
#
# Requires: KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD set before use.
# Requires: jq

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

##############################
# Keycloak helpers
##############################

# Obtain a Keycloak admin access token.
# Requires: KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD
# Sets: token (global)
getKeycloakToken() {
  local raw
  raw=$(curl -s -L "https://$KEYCLOAK_HOST/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode username="$KEYCLOAK_USER" \
    --data-urlencode password="$KEYCLOAK_PASSWORD" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli)
  token=$(echo "$raw" | jq -r '.access_token // empty')

  if [ -z "$token" ]; then
    echo "ERROR: Failed to get Keycloak admin token." >&2
    token=""
    return 1
  fi
}

# Fetch a realm's active RS256 signing key (used to configure JWT auth for CouchDB / replication-backend).
# Requires: KEYCLOAK_HOST, token (call getKeycloakToken first)
# Sets: kid, publicKey (globals). Returns non-zero if the key could not be determined.
getKeycloakRealmKey() {
  local realm="$1"
  local keys
  keys=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/keys" -H "Authorization: Bearer $token")
  kid=$(echo "$keys" | jq -r '.active.RS256 // empty')
  publicKey=$(echo "$keys" | jq -r --arg kid "$kid" '.keys[] | select(.kid==$kid) | .publicKey // empty')
  if [ -z "$kid" ] || [ -z "$publicKey" ]; then
    echo "ERROR: Could not determine active RS256 key for realm '$realm'." >&2
    return 1
  fi
}

# Creates the aam-backend Keycloak client (if it doesn't exist) and assigns required realm-management roles.
# Requires: KEYCLOAK_HOST, token (call getKeycloakToken first or let this function call it)
# Sets: clientSecret (global)
createKeycloakBackendClient() {
  local realm="$1"
  clientSecret=""

  if ! getKeycloakToken; then
    return 1
  fi

  # check if aam-backend client already exists
  local existing existingUuid
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=aam-backend" \
    -H "Authorization: Bearer $token")
  existingUuid=$(echo "$existing" | jq -r '.[0].id // empty')

  if [ -n "$existingUuid" ]; then
    echo "  aam-backend client already exists: $existingUuid"
    clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$existingUuid/client-secret" \
      -H "Authorization: Bearer $token" | jq -r '.value // empty')

    # ensure service account has required realm-management roles (idempotent)
    if ! _assignManageRealmRole "$realm" "$existingUuid"; then
      echo "  ERROR: Failed to ensure realm-management roles for existing aam-backend client in realm '$realm'."
      return 1
    fi
    return 0
  fi

  # create the aam-backend client (confidential, service account enabled)
  local clientResponse location clientUuid
  clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/clients" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "aam-backend",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "serviceAccountsEnabled": true,
      "publicClient": false,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "protocol": "openid-connect"
    }')

  # extract client UUID from Location header
  location=$(echo "$clientResponse" | grep -i "^location:")
  clientUuid=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

  if [ -z "$clientUuid" ]; then
    echo "  ERROR: Failed to create aam-backend client in realm '$realm'."
    return 1
  fi

  echo "  Created aam-backend client: $clientUuid"

  clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/client-secret" \
    -H "Authorization: Bearer $token" | jq -r '.value // empty')

  if [ -z "$clientSecret" ]; then
    echo "  ERROR: Failed to retrieve client secret for aam-backend in realm '$realm'."
    return 1
  fi

  _assignManageRealmRole "$realm" "$clientUuid"
}

# Returns 0 if the aam-backend service account has the given (effective) realm-management role, else 1.
# Use this to verify role assignment actually stuck: createKeycloakBackendClient returns 0 even when
# _assignManageRealmRole only printed warnings, so its exit code is not proof the role is present.
# Requires: KEYCLOAK_HOST, token (call getKeycloakToken first or let this function call it)
serviceAccountHasRealmManagementRole() {
  local realm="$1"
  local roleName="$2"

  if [ -z "${token:-}" ] && ! getKeycloakToken; then
    return 1
  fi

  local aamBackendClientUuid serviceAccountUserId realmMgmtClientUuid
  aamBackendClientUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=aam-backend" \
    -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
  [ -z "$aamBackendClientUuid" ] && return 1

  serviceAccountUserId=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$aamBackendClientUuid/service-account-user" \
    -H "Authorization: Bearer $token" | jq -r '.id // empty')
  [ -z "$serviceAccountUserId" ] && return 1

  realmMgmtClientUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=realm-management" \
    -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
  [ -z "$realmMgmtClientUuid" ] && return 1

  # query effective (composite) role-mappings so manage-users (which contains view-users) also counts
  curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/users/$serviceAccountUserId/role-mappings/clients/$realmMgmtClientUuid/composite" \
    -H "Authorization: Bearer $token" | jq -e --arg r "$roleName" 'any(.[]; .name == $r)' >/dev/null
}

##############################
# Carbone render client helpers
##############################

# CARBONE_REALM is the central realm for Carbone PDF render API access
CARBONE_REALM="aam-platform"

# oauth2-proxy client ID — render clients must include this in their token audience.
OAUTH2_PROXY_CLIENT_ID="carbone-oauth2-proxy"

# Ensure an audience mapper on the given client includes OAUTH2_PROXY_CLIENT_ID
# in the access-token `aud` claim (idempotent — checked by mapper name).
# oauth2-proxy rejects bearer tokens without this audience.
# Args: realm, clientUuid
# Requires: KEYCLOAK_HOST, token (call getKeycloakToken first or let this function call it)
ensureAudienceMapper() {
  local realm="$1"
  local clientUuid="$2"
  local mapperName="audience-${OAUTH2_PROXY_CLIENT_ID}"

  if [ -z "${token:-}" ] && ! getKeycloakToken; then
    return 1
  fi

  local existing
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/protocol-mappers/models" \
    -H "Authorization: Bearer $token" | jq -r --arg n "$mapperName" '.[] | select(.name == $n) | .id // empty')

  if [ -n "$existing" ]; then
    echo "  audience mapper already present on client."
    return 0
  fi

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/protocol-mappers/models" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$mapperName\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"config\": {
        \"included.client.audience\": \"$OAUTH2_PROXY_CLIENT_ID\",
        \"id.token.claim\": \"false\",
        \"access.token.claim\": \"true\",
        \"introspection.token.claim\": \"true\",
        \"userinfo.token.claim\": \"false\"
      }
    }")

  if [ "$status" != "201" ]; then
    echo "  ERROR: failed to add audience mapper (HTTP $status)."
    return 1
  fi
  echo "  Added audience mapper for $OAUTH2_PROXY_CLIENT_ID."
}

# Create a render client in the central aam-platform realm
# Args: realm, clientId
# Sets: clientSecret (global)
# Requires: KEYCLOAK_HOST, token (call getKeycloakToken first or let this function call it)
createCarboneRenderClient() {
  local realm="$1"
  local clientId="$2"
  clientSecret=""

  if ! getKeycloakToken; then
    return 1
  fi

  # check if client already exists
  local existing existingUuid
  existing=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=$clientId" \
    -H "Authorization: Bearer $token")
  existingUuid=$(echo "$existing" | jq -r '.[0].id // empty')

  if [ -n "$existingUuid" ]; then
    echo "  $clientId client already exists in realm $realm: $existingUuid"
    clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$existingUuid/client-secret" \
      -H "Authorization: Bearer $token" | jq -r '.value // empty')
    ensureAudienceMapper "$realm" "$existingUuid" || return 1
    return 0
  fi

  # create the client: confidential, service-account only (no interactive flows)
  local clientResponse location clientUuid
  clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/clients" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"$clientId\",
      \"enabled\": true,
      \"clientAuthenticatorType\": \"client-secret\",
      \"serviceAccountsEnabled\": true,
      \"publicClient\": false,
      \"standardFlowEnabled\": false,
      \"directAccessGrantsEnabled\": false,
      \"protocol\": \"openid-connect\"
    }")

  location=$(echo "$clientResponse" | grep -i "^location:")
  clientUuid=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

  if [ -z "$clientUuid" ]; then
    echo "  ERROR: Failed to create $clientId client in realm '$realm'."
    return 1
  fi

  echo "  Created $clientId client: $clientUuid"

  clientSecret=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$clientUuid/client-secret" \
    -H "Authorization: Bearer $token" | jq -r '.value // empty')

  if [ -z "$clientSecret" ]; then
    echo "  ERROR: Failed to retrieve client secret for $clientId in realm '$realm'."
    return 1
  fi

  ensureAudienceMapper "$realm" "$clientUuid" || return 1
}

##############################
# Internal: realm-management role helpers
##############################

# Internal: assign required realm-management roles to the service account of a client
_assignManageRealmRole() {
  local realm="$1"
  local aamBackendClientUuid="$2"

  local serviceAccountUserId
  serviceAccountUserId=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$aamBackendClientUuid/service-account-user" \
    -H "Authorization: Bearer $token" | jq -r '.id // empty')

  if [ -z "$serviceAccountUserId" ]; then
    echo "  WARNING: Could not get service account user for aam-backend client."
    return 1
  fi

  local realmMgmtClientUuid
  realmMgmtClientUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients?clientId=realm-management" \
    -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

  if [ -z "$realmMgmtClientUuid" ]; then
    echo "  WARNING: Could not find realm-management client in realm '$realm'."
    return 1
  fi

  local rolesToAssign=("manage-realm" "query-users" "view-users" "manage-users")
  local rolePayload="[]"
  local roleName roleResponse

  for roleName in "${rolesToAssign[@]}"; do
    roleResponse=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$realmMgmtClientUuid/roles/$roleName" \
      -H "Authorization: Bearer $token")

    if [ "$(echo "$roleResponse" | jq -r '.name // empty')" = "$roleName" ]; then
      rolePayload=$(echo "$rolePayload" | jq --argjson role "$roleResponse" '. + [$role]')
    else
      echo "  WARNING: Could not resolve realm-management role '$roleName' in realm '$realm'."
    fi
  done

  if [ "$(echo "$rolePayload" | jq 'length')" -gt 0 ]; then
    if ! curl -fsS -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/users/$serviceAccountUserId/role-mappings/clients/$realmMgmtClientUuid" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$rolePayload"; then
      echo "  ERROR: Failed to assign realm-management roles to aam-backend service account in realm '$realm'."
      return 1
    fi
    echo "  Ensured realm-management roles on aam-backend service account: manage-realm, query-users, view-users, manage-users."
  else
    echo "  WARNING: No realm-management roles could be assigned to aam-backend service account."
  fi

  # ensure the "roles" client scope is assigned (required for role claims in the access token)
  local rolesScopeUuid
  rolesScopeUuid=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/client-scopes" \
    -H "Authorization: Bearer $token" | jq -r '.[] | select(.name == "roles") | .id // empty')

  if [ -n "$rolesScopeUuid" ]; then
    curl -s -X PUT "https://$KEYCLOAK_HOST/admin/realms/$realm/clients/$aamBackendClientUuid/default-client-scopes/$rolesScopeUuid" \
      -H "Authorization: Bearer $token"
    echo "  Ensured 'roles' client scope on aam-backend client."
  else
    echo "  WARNING: Could not find 'roles' client scope in realm '$realm'."
  fi
}
