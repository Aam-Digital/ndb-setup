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

##############################
# Keycloak client definitions shipped by aam-services
##############################

# aam-services ships the definitions of the Keycloak clients it depends on in its Docker image. The path, the
# file names and the names of the variables they substitute are a public contract of the image (see its
# keycloak/README.md), so a release carries the permissions that exactly that version needs.
AAM_SERVICES_KEYCLOAK_DIR="/opt/app/keycloak"
AAM_BACKEND_CLIENT_DEFINITION="aam-backend-client.json"
CARBONE_CLIENT_DEFINITION="carbone-render-client.json"

# keycloak-config-cli 6.5.1, the version aam-services verified the definitions with. The second half of the
# tag is the Keycloak it is built against: the one the central Keycloak runs, as for the realm configuration
# jobs of aam-cloud-infrastructure, which import into the same Keycloak. Unlike Keycloak's partial import, it
# also brings an existing client up to date.
KEYCLOAK_CONFIG_CLI_IMAGE="adorsys/keycloak-config-cli:6.5.1-26.5.5"

# Print a client definition out of the aam-services image of a version. Fails when the image does not carry
# it, which is the case for every release older than the one that added them.
# Args: aam-services version, definition file name
getKeycloakClientDefinition() {
  # NB: a later assignment in the same `local` must not reference an earlier one - it would expand to the
  # enclosing scope's value (or empty), not the one being set here.
  local version="$1" file="$2" definition="" image dir container status=0
  image="ghcr.io/aam-digital/aam-services:$version"
  dir=$(mktemp -d) || return 1
  # Copied out of a container that is created but never started, so nothing from the image runs and this does
  # not depend on the tools the image contains. `docker create` pulls an image that is not there (progress on
  # stderr). No `docker pull` here - it would move a floating tag like "latest" away from the image the
  # instance actually runs.
  if container=$(docker create "$image" 2>"$dir/errors"); then
    docker cp "$container:$AAM_SERVICES_KEYCLOAK_DIR/$file" "$dir/definition.json" 2>>"$dir/errors" || status=$?
    docker rm "$container" >/dev/null 2>&1
    [ "$status" -ne 0 ] || definition=$(cat "$dir/definition.json")
  else
    status=1
  fi
  if [ "$status" -ne 0 ] || ! jq -e 'has("clients") and has("users")' <<<"$definition" >/dev/null 2>&1; then
    echo "  ERROR: could not read $AAM_SERVICES_KEYCLOAK_DIR/$file from $image:" >&2
    sed 's/^/    /' "$dir/errors" >&2
    echo "  aam-services releases before the Keycloak client definitions were added do not ship it, but" >&2
    echo "  check the message above - a registry, network or tag problem looks the same from here." >&2
    rm -rf "$dir"
    return 1
  fi
  rm -rf "$dir"
  printf '%s\n' "$definition"
}

# Import a client definition into an EXISTING realm with keycloak-config-cli, which makes the client match
# the file (also removing what older setup scripts granted it). The definition's variables and the admin
# credentials reach the container through the environment of `docker run` (`-e NAME` without a value), never
# on a command line or in a file, so no secret shows up in `ps` or is left behind by an interrupted run.
# Args: realm, definition JSON, NAME=VALUE of a variable the definition substitutes...
importKeycloakClientDefinition() {
  local realm="$1" definition="$2"
  shift 2

  # keycloak-config-cli creates a realm that is not there. An instance whose realm is missing (a typo in
  # INSTANCE_NAME, a realm deleted by accident) must never silently get a new, empty one instead.
  local realmStatus
  realmStatus=$(getKeycloakRealmStatus "$realm")
  if [ "$realmStatus" != "200" ]; then
    echo "  ERROR: realm '$realm' not found on $KEYCLOAK_HOST (HTTP $realmStatus), not importing into it." >&2
    return 1
  fi

  # the definition itself holds no secret, only $(env:NAME) placeholders
  local dir
  dir=$(mktemp -d) || return 1
  printf '%s\n' "$definition" >"$dir/definition.json" || { rm -rf "$dir"; return 1; }

  local passed=() var
  for var in "$@"; do
    passed+=(-e "${var%%=*}")
  done
  local output status=0
  # exported in this subshell only
  output=$(
    export KEYCLOAK_URL="https://$KEYCLOAK_HOST" KEYCLOAK_USER KEYCLOAK_PASSWORD
    for var in "$@"; do
      export "${var?}"
    done
    # IMPORT_VARSUBSTITUTION_ENABLED: the definitions use $(env:NAME) placeholders; an unset one fails the
    #   import rather than importing "".
    # IMPORT_MANAGED_CLIENT=no-delete: clients are the only resource type the definitions declare, so they are
    #   the only one managed. Without no-delete, an import removes the clients earlier imports of the same realm
    #   created: in the shared platform realm every instance's import would delete the render clients of all
    #   the others.
    # IMPORT_CACHE_ENABLED=false: the cache skips a file whose checksum is unchanged, so a client changed by
    #   hand would never be repaired - and the checksum lives on the realm, which instances share for the
    #   render clients.
    # IMPORT_REMOTE_STATE_ENABLED=false: with remote state, keycloak-config-cli records "the clients I created"
    #   on the realm, and the next import in default managed mode deletes those it does not declare itself -
    #   such as the jobs of aam-cloud-infrastructure that keep the realms' shared configuration up to date in
    #   the same Keycloak, which would delete aam-backend.
    docker run --rm \
      -v "$dir/definition.json:/definitions/definition.json:ro" \
      -e KEYCLOAK_URL -e KEYCLOAK_USER -e KEYCLOAK_PASSWORD \
      -e IMPORT_FILES_LOCATIONS=/definitions/definition.json \
      -e IMPORT_VARSUBSTITUTION_ENABLED=true \
      -e IMPORT_MANAGED_CLIENT=no-delete \
      -e IMPORT_CACHE_ENABLED=false \
      -e IMPORT_REMOTE_STATE_ENABLED=false \
      "${passed[@]}" \
      "$KEYCLOAK_CONFIG_CLI_IMAGE" 2>&1
  ) || status=$?
  rm -rf "$dir"
  if [ "$status" -ne 0 ]; then
    echo "  ERROR: keycloak-config-cli failed to import into realm '$realm':" >&2
    printf '%s\n' "$output" | sed 's/^/    /' >&2
    return 1
  fi
}

# Print the client secret of an existing client, or a freshly generated one if the client does not exist.
# The import sets the secret to whatever it is given, so an existing one has to be kept: rotating it would
# break the services that already hold it (aam-backend-service, replication-backend).
# Args: realm, clientId
_keycloakClientSecretOrNew() {
  local realm="$1" clientId="$2" clients uuid secret
  # Only a lookup that succeeded and found nothing means the client is new. A failed one (Keycloak or its
  # proxy briefly down, a refused token, a reply that is not the client list) must not: a new secret imported
  # over the live client would lock out the services that hold the current one.
  if ! clients=$(kcApi GET "$realm/clients?clientId=$clientId") \
    || ! uuid=$(jq -er 'if type == "array" then .[0].id // "" else error end' <<<"$clients" 2>/dev/null); then
    echo "  ERROR: failed to look up the $clientId client in realm '$realm'." >&2
    return 1
  fi
  if [ -z "$uuid" ]; then
    echo "  $clientId does not exist in realm '$realm' yet, creating it with a new secret." >&2
    # 256 bits from the kernel's CSPRNG, as hex: it goes into the JSON of the definition unescaped.
    # (Not generate_password, whose $RANDOM is not a cryptographic generator.)
    secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    if [ "${#secret}" -ne 64 ]; then
      echo "  ERROR: could not generate a secret for the $clientId client." >&2
      return 1
    fi
    printf '%s\n' "$secret"
    return 0
  fi
  if ! secret=$(getKeycloakClientSecret "$realm" "$uuid"); then
    echo "  ERROR: failed to read the secret of the $clientId client in realm '$realm'." >&2
    return 1
  fi
  echo "  $clientId client already exists in realm '$realm' ($uuid), keeping its secret." >&2
  printf '%s\n' "$secret"
}

##############################
# aam-backend client (the backend's and replication-backend's Keycloak admin access)
##############################

# Ensure the realm's aam-backend client matches the definition the given aam-services release ships: the
# client itself, its secret, and the realm-management roles of its service account (verified afterwards).
# Idempotent, and it keeps the secret of an existing client.
# Prints the client secret. Args: realm, aam-services version
ensureKeycloakBackendClient() {
  local realm="$1" version="$2" definition secret
  definition=$(getKeycloakClientDefinition "$version" "$AAM_BACKEND_CLIENT_DEFINITION") || return 1
  secret=$(_keycloakClientSecretOrNew "$realm" aam-backend) || return 1

  importKeycloakClientDefinition "$realm" "$definition" \
    "AAM_BACKEND_REALM=$realm" "AAM_BACKEND_CLIENT_SECRET=$secret" || return 1
  if ! backendServiceAccountRolesMatch "$realm" "$definition"; then
    echo "  ERROR: the realm-management roles of the aam-backend service account in realm '$realm' do not" >&2
    echo "  match the definition of aam-services $version after the import." >&2
    return 1
  fi
  echo "  aam-backend client in realm '$realm' matches the definition of aam-services $version." >&2
  printf '%s\n' "$secret"
}

# Print the realm-management roles a definition gives the aam-backend service account, one per line, sorted.
# Args: definition JSON
_definitionBackendRoles() {
  jq -r '.users[] | select(.serviceAccountClientId == "aam-backend")
         | .clientRoles["realm-management"][]' <<<"$1" 2>/dev/null | sort
}

# Returns 0 if the aam-backend service account holds exactly the realm-management roles of the definition.
# Checked on the direct role mappings, not the composites: the point of the import is also that roles older
# setup scripts granted (manage-realm, query-users) are gone, and a composite check would never see that.
# Args: realm, definition JSON
backendServiceAccountRolesMatch() {
  local realm="$1" definition="$2" clientUuid userId mgmtUuid mappings actual expected
  expected=$(_definitionBackendRoles "$definition")
  [ -n "$expected" ] || return 1
  clientUuid=$(getKeycloakClientUuid "$realm" aam-backend) || return 1
  userId=$(kcApi GET "$realm/clients/$clientUuid/service-account-user" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$userId" ] || return 1
  mgmtUuid=$(getKeycloakClientUuid "$realm" realm-management) || return 1
  mappings=$(kcApi GET "$realm/users/$userId/role-mappings/clients/$mgmtUuid") || return 1
  actual=$(jq -r '.[].name' <<<"$mappings" 2>/dev/null | sort)
  [ "$actual" = "$expected" ]
}

# Returns 0 if the aam-backend service account has all the given (effective) realm-management roles, else 1.
# "Has at least", for callers that only depend on a single role; the full set is checked against the
# definition by backendServiceAccountRolesMatch.
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

##############################
# Carbone render client helpers
##############################

# CARBONE_REALM is the central realm for Carbone PDF render API access
CARBONE_REALM="aam-platform"

# oauth2-proxy client ID — render clients must include this in their token audience.
OAUTH2_PROXY_CLIENT_ID="carbone-oauth2-proxy"

# Ensure an instance's render client in the shared platform realm matches the definition the given
# aam-services release ships, including the audience mapper that the oauth2-proxy in front of Carbone needs
# (it rejects a token without OAUTH2_PROXY_CLIENT_ID in its audience). Idempotent, and it keeps the secret of
# an existing client. The definition builds the client id as "carbone-<instance>".
# Prints the client secret. Args: realm, instance name, aam-services version
ensureCarboneRenderClient() {
  local realm="$1" instance="$2" version="$3" clientId="carbone-$2" definition secret
  definition=$(getKeycloakClientDefinition "$version" "$CARBONE_CLIENT_DEFINITION") || return 1
  secret=$(_keycloakClientSecretOrNew "$realm" "$clientId") || return 1

  importKeycloakClientDefinition "$realm" "$definition" \
    "CARBONE_REALM=$realm" "INSTANCE_NAME=$instance" "CARBONE_CLIENT_SECRET=$secret" \
    "OAUTH2_PROXY_CLIENT_ID=$OAUTH2_PROXY_CLIENT_ID" || return 1
  if ! carboneClientHasAudienceMapper "$realm" "$clientId"; then
    echo "  ERROR: the $clientId client in realm '$realm' has no audience mapper for" >&2
    echo "  $OAUTH2_PROXY_CLIENT_ID after the import; Carbone would reject its tokens." >&2
    return 1
  fi
  echo "  $clientId client in realm '$realm' matches the definition of aam-services $version." >&2
  printf '%s\n' "$secret"
}

# Returns 0 if the client has a mapper putting OAUTH2_PROXY_CLIENT_ID into the token audience (checked by
# what the mapper does, not by its name). Args: realm, clientId
carboneClientHasAudienceMapper() {
  local realm="$1" uuid mappers
  uuid=$(getKeycloakClientUuid "$realm" "$2") || return 1
  mappers=$(kcApi GET "$realm/clients/$uuid/protocol-mappers/models") || return 1
  jq -e --arg a "$OAUTH2_PROXY_CLIENT_ID" 'any(.[];
      .protocolMapper == "oidc-audience-mapper"
      and .config["included.client.audience"] == $a
      and .config["access.token.claim"] == "true")' <<<"$mappers" >/dev/null 2>&1
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
