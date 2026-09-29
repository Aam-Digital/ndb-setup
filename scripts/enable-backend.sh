#!/bin/bash

# This script will enable the backend for a customer instance.
# For each instance, this script creates a dedicated Keycloak client in the central aam-platform realm
# for Carbone PDF render API access (named carbone-{instance}).
# Credentials are resolved via getConfig: from setup.env / the environment, falling back to the
# Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set (so it can run without BWS access).

# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./enable-backend.sh <instance>
# example: ./enable-backend.sh qm
#   <instance>  an instance name (standard $baseDirectory/$PREFIX<name> layout) OR a path to the
#               instance directory (e.g. "." when run from inside it)
#
# Re-running it on an instance with the backend already enabled only repairs its config (Keycloak admin access,
# replication-backend's permission-check client and CouchDB credentials, the Carbone render API - see
# repairBackendConfig) and recreates the services whose config changed. For all instances with the backend:
#   ./for-each-instance.sh --only backend ./enable-backend.sh
#
# Requires: CARBONE_HOST and KEYCLOAK_HOST set in setup.env (environment-specific):
#   Environment  KEYCLOAK_HOST                  CARBONE_HOST
#   -----------  -----------------------------  --------------------------------
#   Staging      keycloak.aam-digital.net        pdf.dev-cluster.aam-digital.net
#   Production   keycloak.aam-digital.com        pdf.aam-digital.app
#
# KEYCLOAK_HOST may also be fetched automatically via BWS_ACCESS_TOKEN instead of
# setting it directly in setup.env (KEYCLOAK_USER/KEYCLOAK_PASSWORD are also needed then).
# Requires: the aam-platform realm to already exist on the central Keycloak.
#

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
# parse flags
##############################

# --skip-restart: do not restart docker at the end; the caller (e.g. interactive-setup.sh) is responsible
# for bringing the stack up once, after all enable-* scripts have written their config. Run standalone
# (without the flag) the script restarts itself. Flags are stripped here so positional args stay intact.
skipRestart=false
positionalArgs=()
for arg in "$@"; do
  case "$arg" in
    --skip-restart) skipRestart=true ;;
    *) positionalArgs+=("$arg") ;;
  esac
done
set -- "${positionalArgs[@]+"${positionalArgs[@]}"}"

##############################
# backend config (shared by enabling and repairing)
##############################

# Fail unless the Carbone PDF render API can be wired up: CARBONE_HOST set and the aam-platform realm
# present on the central Keycloak. Requires: KEYCLOAK_HOST, token.
checkCarbonePrerequisites() {
  if [[ -z "${CARBONE_HOST:-}" ]]; then
    echo "ERROR: CARBONE_HOST is not set in setup.env."
    echo "  Staging:    CARBONE_HOST=pdf.dev-cluster.aam-digital.net"
    echo "  Production: CARBONE_HOST=pdf.aam-digital.app"
    return 1
  fi
  local realmStatus
  realmStatus=$(getKeycloakRealmStatus "$CARBONE_REALM")
  if [ "$realmStatus" != "200" ]; then
    echo "ERROR: Realm '$CARBONE_REALM' not found on $KEYCLOAK_HOST (HTTP $realmStatus)."
    echo "Create it first — see aam-cloud-infrastructure/infra/src/aam-platform/README.md > Initial setup."
    return 1
  fi
}

# Write the Carbone PDF render API config. Args: application.env, render client id, render client secret
writeRenderApiConfig() {
  local appEnv="$1" clientId="$2" clientSecret="$3"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH "https://$CARBONE_HOST" "$appEnv"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID "$clientId" "$appEnv"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET "$clientSecret" "$appEnv"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT "https://$KEYCLOAK_HOST/realms/$CARBONE_REALM/protocol/openid-connect/token" "$appEnv"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE "client_credentials" "$appEnv"
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE "openid" "$appEnv"
  upsertEnv FEATURES_EXPORT_API_ENABLED "true" "$appEnv"
}

# Whether the render API config is complete: the per-instance values are set, the static ones match, and
# the token endpoint no longer points to the old shared "aam-digital" realm. Args: application.env
renderApiConfigUpToDate() {
  local appEnv="$1" var
  for var in AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET \
             AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT; do
    grep -qE "^$var=.+" "$appEnv" 2>/dev/null || return 1
  done
  grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE=client_credentials$" "$appEnv" 2>/dev/null || return 1
  grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE=openid$" "$appEnv" 2>/dev/null || return 1
  grep -q "^FEATURES_EXPORT_API_ENABLED=true$" "$appEnv" 2>/dev/null || return 1
  ! grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT=.*/realms/aam-digital/" "$appEnv" 2>/dev/null
}

# Write the CouchDB credentials the backend uses for replication-backend (permission checks), CouchDB and
# SQS. BASEPATH is defined (and overridden) by docker-compose, so a value in application.env is dead
# config. Args: application.env, instance .env
writeCouchdbClientCredentials() {
  local appEnv="$1" envFile="$2" couchUser couchPass
  couchUser=$(getVar "$envFile" COUCHDB_USER)
  couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)
  removeEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH "$appEnv"
  upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv"
  upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv"
  upsertEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv"
  upsertEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv"
  upsertEnv SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv"
  upsertEnv SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv"
}

# Whether writeCouchdbClientCredentials would change nothing. A missing or wrong value makes every
# permission check fail with 401. Args: application.env, instance .env
couchdbClientCredentialsUpToDate() {
  local appEnv="$1" envFile="$2" couchUser couchPass prefix
  couchUser=$(getVar "$envFile" COUCHDB_USER)
  couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)
  grep -q "^AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH=" "$appEnv" 2>/dev/null && return 1
  for prefix in AAMREPLICATIONBACKENDCLIENTCONFIGURATION COUCHDBCLIENTCONFIGURATION SQSCLIENTCONFIGURATION; do
    [ "$(getVar "$appEnv" "${prefix}_BASICAUTHUSERNAME")" == "$couchUser" ] || return 1
    [ "$(getVar "$appEnv" "${prefix}_BASICAUTHPASSWORD")" == "$couchPass" ] || return 1
  done
}

# Point replication-backend's permission checks at the aam-backend client (an existing placeholder like
# NOT_USED as client id is corrected). Args: instance .env, aam-backend client secret
writeReplicationBackendKeycloakClient() {
  local envFile="$1" secret="$2"
  ensureRealValue REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID "aam-backend" "$envFile"
  upsertEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$secret" "$envFile"
}

##############################
# already enabled: repair the backend config
##############################

# Bring an instance with the backend already enabled up to date, recreating only the services whose config
# changed:
# - Keycloak admin access: the aam-backend service account's realm-management roles (incl. "manage-clients")
#   and KEYCLOAK_* in application.env. Without it, API clients relying on the client scopes the backend
#   provisions are denied access (HTTP 403).
# - replication-backend's permission checks: the aam-backend client in .env, and matching CouchDB
#   credentials in application.env.
# - the Carbone PDF render API (a per-instance "carbone-<instance>" client in the aam-platform realm).
# Uses the globals path and instance.
repairBackendConfig() {
  local appEnv="$path/config/aam-backend-service/application.env"
  local envFile="$path/.env"

  requireConfig KEYCLOAK_HOST
  requireConfig KEYCLOAK_PASSWORD
  requireConfig KEYCLOAK_USER
  token=""   # the admin token is short-lived, get a fresh one for each instance

  # the admin credentials only reach the central Keycloak: an instance using another one cannot be repaired here
  local instanceKeycloakHost
  instanceKeycloakHost=$(getVar "$envFile" KEYCLOAK_URL "$KEYCLOAK_HOST")
  if [ "$instanceKeycloakHost" != "$KEYCLOAK_HOST" ]; then
    echo "ERROR: '$instance' uses Keycloak '$instanceKeycloakHost' (KEYCLOAK_URL in .env), not '$KEYCLOAK_HOST'. Cannot repair it with these admin credentials."
    return 1
  fi
  if ! getKeycloakToken; then
    return 1
  fi
  local realmStatus
  realmStatus=$(getKeycloakRealmStatus "$instance")
  if [ "$realmStatus" != "200" ]; then
    echo "ERROR: Realm '$instance' not accessible on $KEYCLOAK_HOST (HTTP $realmStatus). Check the realm exists (and matches INSTANCE_NAME)."
    return 1
  fi

  # what is out of date
  local repairs=()
  local keycloakSecret
  keycloakSecret=$(getKeycloakBackendClientSecret "$instance")
  if ! { [ -n "$keycloakSecret" ] \
    && ! isPlaceholderValue "$(getVar "$appEnv" KEYCLOAK_SERVERURL)" \
    && [ "$(getVar "$appEnv" KEYCLOAK_REALM)" == "$instance" ] \
    && [ "$(getVar "$appEnv" KEYCLOAK_CLIENTID)" == "aam-backend" ] \
    && [ "$(getVar "$appEnv" KEYCLOAK_CLIENTSECRET)" == "$keycloakSecret" ] \
    && serviceAccountHasRealmManagementRole "$instance" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; }; then
    repairs+=(keycloak-admin)
  fi
  if isPlaceholderValue "$(getVar "$envFile" REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID)" \
    || [ -z "$keycloakSecret" ] \
    || [ "$(getVar "$envFile" REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET)" != "$keycloakSecret" ]; then
    repairs+=(replication-backend-client)
  fi
  couchdbClientCredentialsUpToDate "$appEnv" "$envFile" || repairs+=(couchdb-credentials)
  renderApiConfigUpToDate "$appEnv" || repairs+=(render-api)

  if [ "${#repairs[@]}" -eq 0 ]; then
    echo "Backend already enabled for '$instance' and its config is up to date. Nothing to do."
    return 0
  fi
  echo "Backend already enabled for '$instance'. Repairing: ${repairs[*]}"
  needs() { [[ " ${repairs[*]} " == *" $1 "* ]]; }

  # Keycloak first, so a failure does not leave a config pointing at a client without the needed access.
  # Both clients' secrets are copied right away: the create* helpers return them in the same global.
  local backendSecret="" carboneSecret=""
  if needs keycloak-admin || needs replication-backend-client; then
    if ! createKeycloakBackendClient "$instance" || [ -z "$clientSecret" ]; then
      echo "ERROR: Failed to create/get the aam-backend Keycloak client (or its secret) for '$instance'."
      return 1
    fi
    backendSecret="$clientSecret"
    # createKeycloakBackendClient returns 0 even if the role assignment only warned
    if ! serviceAccountHasRealmManagementRole "$instance" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; then
      echo "ERROR: Could not confirm the realm-management roles (${AAM_BACKEND_REALM_MANAGEMENT_ROLES[*]}) on the aam-backend service account."
      return 1
    fi
  fi
  if needs render-api; then
    checkCarbonePrerequisites || return 1
    if ! createCarboneRenderClient "$CARBONE_REALM" "carbone-${instance}" || [ -z "$clientSecret" ]; then
      echo "ERROR: Failed to create/get the Keycloak render client (or its secret) for '$instance'."
      return 1
    fi
    carboneSecret="$clientSecret"
  fi

  local servicesToRecreate=()
  if needs keycloak-admin || needs couchdb-credentials || needs render-api; then
    backupFile "$appEnv"
    servicesToRecreate+=("aam-backend-service")
  fi
  if needs keycloak-admin; then
    ensureBackendKeycloakAdminConfig "$appEnv" "https://$(getVar "$envFile" KEYCLOAK_URL "$KEYCLOAK_HOST")" "$instance" "$backendSecret"
  fi
  if needs couchdb-credentials; then
    writeCouchdbClientCredentials "$appEnv" "$envFile"
  fi
  if needs render-api; then
    writeRenderApiConfig "$appEnv" "carbone-${instance}" "$carboneSecret"
  fi
  if needs replication-backend-client; then
    backupFile "$envFile"
    writeReplicationBackendKeycloakClient "$envFile" "$backendSecret"
    servicesToRecreate+=("replication-backend")
  fi

  if [ "$skipRestart" != "true" ]; then
    # force-recreate: also when only the role changed, the backend must restart to run its startup provisioning
    if ! (cd "$path" && docker compose up -d --force-recreate "${servicesToRecreate[@]}"); then
      echo "ERROR: Failed to recreate ${servicesToRecreate[*]} for '$instance'. Recreate it manually to apply the repair."
      return 1
    fi
  fi
  echo "Backend config repaired: ${repairs[*]}."
}

##############################
# ask for input data
##############################

if [ -n "$1" ]; then
  instanceArg="$1"
else
  echo "Which instance? (name, or path to the instance directory, e.g. '.')"
  read -r instanceArg
fi
resolveInstancePath "$instanceArg" || exit 1
instance=$(getVar "$path/.env" INSTANCE_NAME)
if [ -z "$instance" ]; then
  instance="$(basename "$path")"
  instance="${instance#"$PREFIX"}"
fi

if backendEnabledCheck && isBackendConfigCreated; then
  repairBackendConfig
  exit $?
fi

# This script wires the app container's /db and /api routes to replication-backend /
# aam-backend-service via env vars (DB_ENTRYPOINT_URL, API_BACKEND_URL) that only the current
# docker-compose.yml schema reads. An instance still on an older schema ignores those vars
# entirely, so switching profiles would silently look like it worked while /db and /api keep
# going wherever that old schema already pointed them - update-compose.sh must run first.
if ! diff -q "$path/docker-compose.yml" "$ndbSetupDir/docker-compose.yml" >/dev/null 2>&1; then
  echo "ERROR: '$path/docker-compose.yml' differs from the canonical $ndbSetupDir/docker-compose.yml."
  echo "  Run update-compose.sh for this instance first, then retry."
  exit 1
fi

##############################
# variables
##############################

# resolve config from setup.env / environment, falling back to Bitwarden when a token is available
requireConfig SENTRY_AUTH_TOKEN
requireConfig SENTRY_DSN_BACKEND
requireConfig KEYCLOAK_HOST
requireConfig KEYCLOAK_PASSWORD
requireConfig KEYCLOAK_USER


##############################
# script
##############################

backendVersion=$(getLatestBackendVersion)
echo "Latest backendVersion available: $backendVersion"

# check if backend is already enabled for this instance
if backendEnabledCheck; then
  echo "Backend already enabled for '$instance'. Abort."
  exit 1
fi

if isBackendConfigCreated; then
  echo "Backend config already created for '$instance'. Abort."
  exit 1
fi

if ! replicationBackendEnabledCheck; then
  # all functionality should be the same with a direct CouchDB without replication-backend. However, some URLs will need to be adapted for this scenario
  echo "Replication Backend is required for backend. Please enable first. Abort."
  exit 1
fi

# Preflight: CARBONE_HOST set and the aam-platform realm present on the central Keycloak
if ! getKeycloakToken; then
  echo "ERROR: Failed to authenticate with Keycloak. Abort."
  exit 1
fi
checkCarbonePrerequisites || exit 1

# latest template config (from aam-services repository), fetched before anything is stopped or changed
templateFile=$(mktemp)
trap 'rm -f "$templateFile"' EXIT
downloadBackendConfigTemplate "$backendVersion" "$templateFile" || exit 1

(cd "$path" && docker compose down)

backupFile "$path/.env"

# set aam-backend-service-version to supported version
setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

# create backend config directory
mkdir -p "$path/config/aam-backend-service"

cp "$templateFile" "$path/config/aam-backend-service/application.env"

setEnv CRYPTO_CONFIGURATION_SECRET "$(generate_password)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI "https://$KEYCLOAK_HOST/realms/$instance" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_USERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_PASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"

writeCouchdbClientCredentials "$path/config/aam-backend-service/application.env" "$path/.env"

# Create a per-instance Carbone render client in the aam-platform realm
carboneClientId="carbone-${instance}"
if ! createCarboneRenderClient "$CARBONE_REALM" "$carboneClientId"; then
  echo "ERROR: Failed to create or fetch Keycloak render client for '$instance'. Aborting."
  exit 1
fi
carboneClientSecret="$clientSecret"
if [ -z "$carboneClientSecret" ]; then
  echo "ERROR: Carbone render client created/fetched but secret could not be retrieved for '$instance'. Aborting."
  exit 1
fi

writeRenderApiConfig "$path/config/aam-backend-service/application.env" "$carboneClientId" "$carboneClientSecret"
setEnv SENTRY_AUTH_TOKEN "$SENTRY_AUTH_TOKEN" "$path/config/aam-backend-service/application.env"
setEnv SENTRY_DSN "$SENTRY_DSN_BACKEND" "$path/config/aam-backend-service/application.env"
setEnv SENTRY_SERVER_NAME "$instance.$DOMAIN" "$path/config/aam-backend-service/application.env"

# create aam-backend Keycloak client for permission checks
if ! createKeycloakBackendClient "$instance"; then
  echo "ERROR: Failed to create/get Keycloak backend client for '$instance'. Aborting."
  exit 1
fi
if [ -z "$clientSecret" ]; then
  echo "ERROR: Keycloak client created but secret could not be retrieved for '$instance'. Aborting."
  exit 1
fi

# the backend also uses this client for Keycloak admin access (e.g. provisioning the client scopes of its API)
ensureBackendKeycloakAdminConfig "$path/config/aam-backend-service/application.env" "https://$KEYCLOAK_HOST" "$instance" "$clientSecret"

writeReplicationBackendKeycloakClient "$path/.env" "$clientSecret"

setEnv COMPOSE_PROFILES "full-stack" "$path/.env"
# the app container's /db now needs to reach replication-backend instead of CouchDB directly
upsertEnv DB_ENTRYPOINT_URL "http://${instance}-replication-backend:5984" "$path/.env"
# ...and its /api now needs to reach aam-backend-service, which this profile also deploys
upsertEnv API_BACKEND_URL "http://${instance}-aam-backend-service:8080" "$path/.env"

# ensure CouchDB is locked down for replication-backend (admin-only _security, no JWT auth, no anonymous access)
if ! "$scriptDir/create-couchdb.sh" "$path" --with-permissions; then
  echo "ERROR: Failed to lock down CouchDB for '$instance'. Fix it and re-run create-couchdb.sh before starting the stack."
  exit 1
fi

if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose up -d)
fi

echo "Backend enabled."
