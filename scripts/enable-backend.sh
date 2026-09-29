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
# Re-running it on an instance with the backend already enabled only repairs the backend's Keycloak admin
# access (realm-management roles incl. "manage-clients", KEYCLOAK_* in application.env) and recreates the
# backend if something changed. To do this for all instances that have the backend enabled (others are skipped):
#   ./enable-backend.sh --repair-all
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
# --repair-all: only repair the backend's Keycloak admin access of every instance with the backend enabled.
skipRestart=false
repairAll=false
positionalArgs=()
for arg in "$@"; do
  case "$arg" in
    --skip-restart) skipRestart=true ;;
    --repair-all) repairAll=true ;;
    *) positionalArgs+=("$arg") ;;
  esac
done
set -- "${positionalArgs[@]+"${positionalArgs[@]}"}"

##############################
# already enabled: repair Keycloak admin access only
##############################

# Ensure the aam-backend service account has the realm-management roles (incl. "manage-clients") and the
# backend has its Keycloak admin client configured. Instances enabled before the backend managed its
# client scopes itself lack this, so API clients relying on those scopes are denied access (HTTP 403).
# Uses the globals path and instance.
repairBackendKeycloakAdminAccess() {
  local appEnv="$path/config/aam-backend-service/application.env"

  requireConfig KEYCLOAK_HOST
  requireConfig KEYCLOAK_PASSWORD
  requireConfig KEYCLOAK_USER
  token=""   # the admin token is short-lived, get a fresh one for each instance

  # the admin credentials only reach the central Keycloak: an instance using another one cannot be repaired here
  local instanceKeycloakHost
  instanceKeycloakHost=$(getVar "$path/.env" KEYCLOAK_URL "$KEYCLOAK_HOST")
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

  # up-to-date only if the config matches the aam-backend client of this realm and it has all roles
  local keycloakSecret replicationBackendSecret
  keycloakSecret=$(getKeycloakBackendClientSecret "$instance")
  replicationBackendSecret=$(getVar "$path/.env" REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET)
  if [ -n "$keycloakSecret" ] \
    && ! isPlaceholderValue "$(getVar "$appEnv" KEYCLOAK_SERVERURL)" \
    && [ "$(getVar "$appEnv" KEYCLOAK_REALM)" == "$instance" ] \
    && [ "$(getVar "$appEnv" KEYCLOAK_CLIENTID)" == "aam-backend" ] \
    && [ "$(getVar "$appEnv" KEYCLOAK_CLIENTSECRET)" == "$keycloakSecret" ] \
    && { [ -z "$replicationBackendSecret" ] || [ "$replicationBackendSecret" == "$keycloakSecret" ]; } \
    && serviceAccountHasRealmManagementRole "$instance" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "Backend already enabled for '$instance', including its Keycloak admin access. Nothing to do."
    return 0
  fi

  echo "Backend already enabled for '$instance', but its Keycloak admin access is incomplete. Repairing..."

  # Keycloak first, so a failure does not leave a config pointing at a client without the needed access
  if ! createKeycloakBackendClient "$instance" || [ -z "$clientSecret" ]; then
    echo "ERROR: Failed to create/get the aam-backend Keycloak client (or its secret) for '$instance'."
    return 1
  fi
  # createKeycloakBackendClient returns 0 even if the role assignment only warned
  if ! serviceAccountHasRealmManagementRole "$instance" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; then
    echo "ERROR: Could not confirm the realm-management roles (${AAM_BACKEND_REALM_MANAGEMENT_ROLES[*]}) on the aam-backend service account."
    return 1
  fi

  backupFile "$appEnv"
  ensureBackendKeycloakAdminConfig "$appEnv" "https://$(getVar "$path/.env" KEYCLOAK_URL "$KEYCLOAK_HOST")" "$instance" "$clientSecret"

  # keep .env in sync, the replication-backend uses the same client
  local servicesToRecreate=("aam-backend-service")
  if [ -n "$replicationBackendSecret" ] && [ "$replicationBackendSecret" != "$clientSecret" ]; then
    backupFile "$path/.env"
    setEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$clientSecret" "$path/.env"
    servicesToRecreate+=("replication-backend")
  fi

  if [ "$skipRestart" != "true" ]; then
    # force-recreate: also when only the role changed, the backend must restart to run its startup provisioning
    if ! (cd "$path" && docker compose up -d --force-recreate "${servicesToRecreate[@]}"); then
      echo "ERROR: Failed to recreate ${servicesToRecreate[*]} for '$instance'. Recreate it manually to apply the repair."
      return 1
    fi
  fi
  echo "Keycloak admin access of the backend repaired."
}

if [ "$repairAll" = true ]; then
  if [ "$#" -gt 0 ]; then
    echo "ERROR: --repair-all repairs all instances and takes no instance argument (got: $*)."
    echo "  To repair a single instance, run: $0 <instance>"
    exit 1
  fi
  # resolved (and exported) once here, so each per-instance run does not fetch them from BWS again
  requireConfig KEYCLOAK_HOST
  requireConfig KEYCLOAK_PASSWORD
  requireConfig KEYCLOAK_USER
  backendEnabledAt() { local path="$1"; backendEnabledCheck && isBackendConfigCreated; }
  # re-running this script on an instance with the backend enabled only repairs it (see above)
  repairArgs=()
  [ "$skipRestart" = true ] && repairArgs+=(--skip-restart)
  runForEachInstance backendEnabledAt "backend not enabled" "$0" "${repairArgs[@]+"${repairArgs[@]}"}"
  exit $?
fi

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
  repairBackendKeycloakAdminAccess
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

# Preflight: confirm aam-platform realm exists on the central Keycloak
if ! getKeycloakToken; then
  echo "ERROR: Failed to authenticate with Keycloak. Abort."
  exit 1
fi
realmStatus=$(curl -s -o /dev/null -w "%{http_code}" "https://$KEYCLOAK_HOST/admin/realms/$CARBONE_REALM" \
  -H "Authorization: Bearer $token")
if [ "$realmStatus" != "200" ]; then
  echo "ERROR: Realm '$CARBONE_REALM' not found on $KEYCLOAK_HOST (HTTP $realmStatus)."
  echo "Create it first — see aam-cloud-infrastructure/infra/src/aam-platform/README.md > Initial setup."
  exit 1
fi

(cd "$path" && docker compose down)

backupFile "$path/.env"

# set aam-backend-service-version to supported version
setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

# create backend config directory
mkdir -p "$path/config/aam-backend-service"

# copy latest template config (from aam-services repository)
curl -L -o "$path/config/aam-backend-service/application.env" "https://raw.githubusercontent.com/Aam-Digital/aam-services/refs/tags/aam-backend-service/$backendVersion/templates/aam-backend-service/application.template.env"

setEnv CRYPTO_CONFIGURATION_SECRET "$(generate_password)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI "https://$KEYCLOAK_HOST/realms/$instance" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_USERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SPRING_DATASOURCE_PASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"

# BASEPATH is defined (and overridden) by docker-compose — remove any value the template ships so it
# is not duplicated as dead config in application.env.
removeEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH "$path/config/aam-backend-service/application.env"
upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
setEnv SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
if [[ -z "${CARBONE_HOST:-}" ]]; then
  echo "ERROR: CARBONE_HOST is not set in setup.env."
  echo "  Staging:    CARBONE_HOST=pdf.dev-cluster.aam-digital.net"
  echo "  Production: CARBONE_HOST=pdf.aam-digital.app"
  exit 1
fi

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

tokenEndpoint="https://$KEYCLOAK_HOST/realms/$CARBONE_REALM/protocol/openid-connect/token"

setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH "https://$CARBONE_HOST" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID "$carboneClientId" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET "$carboneClientSecret" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT "$tokenEndpoint" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE "client_credentials" "$path/config/aam-backend-service/application.env"
ensureEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE "openid" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE "openid" "$path/config/aam-backend-service/application.env"
ensureEnv FEATURES_EXPORT_API_ENABLED "true" "$path/config/aam-backend-service/application.env"
setEnv FEATURES_EXPORT_API_ENABLED "true" "$path/config/aam-backend-service/application.env"
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

# ensure the client ID is set (and correct an existing placeholder like NOT_USED)
ensureRealValue REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID "aam-backend" "$path/.env"

# ensure key exists before setting (older .env templates may lack it)
if ! grep -q '^REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=' "$path/.env"; then
  echo "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=" >> "$path/.env"
fi
setEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$clientSecret" "$path/.env"

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
