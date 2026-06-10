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
    _assignManageRealmRole "$realm" "$existingUuid"
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
    curl -s -X POST "https://$KEYCLOAK_HOST/admin/realms/$realm/users/$serviceAccountUserId/role-mappings/clients/$realmMgmtClientUuid" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$rolePayload"
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
