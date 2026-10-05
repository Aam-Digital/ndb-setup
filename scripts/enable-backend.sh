#!/bin/bash
usage() {
  cat <<'EOF'
Enable aam-backend-service for an instance: write its application.env, create the Keycloak clients it needs
(including carbone-<instance> in the central aam-platform realm for the Carbone PDF render API) and start it.

Usage:
  ./enable-backend.sh <instance> [--repair-only] [--skip-restart]

  --repair-only   only repair an instance that already has the backend; skip (without failing) one that
                  doesn't. Without it, an instance with replication-backend but no backend gets the
                  backend newly enabled - a profile change, not a repair.

Requires replication-backend, the canonical docker-compose.yml (run update-compose.sh first) and the
aam-platform realm on the central Keycloak.

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set; see setup.example.env):
  CARBONE_HOST, KEYCLOAK_HOST, KEYCLOAK_USER, KEYCLOAK_PASSWORD, SENTRY_AUTH_TOKEN, SENTRY_DSN_BACKEND

Re-running it on an instance with the backend already enabled only repairs its config (Keycloak admin access,
replication-backend's permission-check client and CouchDB credentials, the Carbone render API client, and
dropping the dead PostgreSQL/RabbitMQ keys of backends that still had their own database) and recreates the
services whose config changed. For all instances with the backend, either form - the first selects them by
profile, the second lets every instance decide for itself, so a run that forgets the filter still repairs
instead of enabling:
  ./for-each-instance.sh --only backend ./enable-backend.sh
  ./for-each-instance.sh ./enable-backend.sh --repair-only
EOF
  exit "${1:-1}"
}

# The repair on a re-run is repairBackendConfig, built from the same functions as the first run.

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

# --repair-only, stripped from "$@" like --skip-restart so the positional args stay intact.
# Without it this script *enables* the backend on an instance that has none, which for a
# with-permissions instance is a silent profile change rather than a repair - so a fleet-wide
# run either filters with `for-each-instance.sh --only backend` or passes this flag.
repairOnly=false
_enableBackendArgs=()
for _enableBackendArg in "$@"; do
  case "$_enableBackendArg" in
    --repair-only) repairOnly=true ;;
    *) _enableBackendArgs+=("$_enableBackendArg") ;;
  esac
done
set -- "${_enableBackendArgs[@]+"${_enableBackendArgs[@]}"}"
unset _enableBackendArg _enableBackendArgs

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
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH "https://$CARBONE_HOST" "$appEnv" || return 1
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID "$clientId" "$appEnv" || return 1
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET "$clientSecret" "$appEnv" || return 1
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT "https://$KEYCLOAK_HOST/realms/$CARBONE_REALM/protocol/openid-connect/token" "$appEnv" || return 1
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE "client_credentials" "$appEnv" || return 1
  upsertEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE "openid" "$appEnv" || return 1
  upsertEnv FEATURES_EXPORTAPI_ENABLED "true" "$appEnv" || return 1
  # misspelled key written by earlier versions of this script: the backend reads it as a fallback only, so a
  # FEATURES_EXPORTAPI_ENABLED=false from the template overrides it
  removeEnv FEATURES_EXPORT_API_ENABLED "$appEnv" || return 1
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
  grep -q "^FEATURES_EXPORTAPI_ENABLED=true$" "$appEnv" 2>/dev/null || return 1
  ! grep -q "^FEATURES_EXPORT_API_ENABLED=" "$appEnv" 2>/dev/null || return 1
  ! grep -q "^AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT=.*/realms/aam-digital/" "$appEnv" 2>/dev/null
}

# Whether the instance's docker-compose.yml defines (and so overrides) the replication-backend BASEPATH -
# only then is a value in application.env dead config. Older compose files rely on application.env.
# Args: instance dir
composeDefinesReplicationBackendBasePath() {
  grep -q "AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH:" "$1/docker-compose.yml" 2>/dev/null
}

# Write the CouchDB credentials the backend uses for replication-backend (permission checks), CouchDB and
# SQS, and drop a BASEPATH that docker-compose overrides anyway. Args: application.env, instance .env, instance dir
writeCouchdbClientCredentials() {
  local appEnv="$1" envFile="$2" instanceDir="$3" couchUser couchPass
  couchUser=$(getVar "$envFile" COUCHDB_USER)
  couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)
  if composeDefinesReplicationBackendBasePath "$instanceDir"; then
    removeEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH "$appEnv" || return 1
  fi
  upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv" || return 1
  upsertEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv" || return 1
  upsertEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv" || return 1
  upsertEnv COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv" || return 1
  upsertEnv SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME "$couchUser" "$appEnv" || return 1
  upsertEnv SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD "$couchPass" "$appEnv" || return 1
}

# Whether writeCouchdbClientCredentials would change nothing. A missing or wrong value makes every
# permission check fail with 401. Args: application.env, instance .env, instance dir
couchdbClientCredentialsUpToDate() {
  local appEnv="$1" envFile="$2" instanceDir="$3" couchUser couchPass prefix
  couchUser=$(getVar "$envFile" COUCHDB_USER)
  couchPass=$(getVar "$envFile" COUCHDB_PASSWORD)
  if composeDefinesReplicationBackendBasePath "$instanceDir" \
    && grep -q "^AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASEPATH=" "$appEnv" 2>/dev/null; then
    return 1
  fi
  for prefix in AAMREPLICATIONBACKENDCLIENTCONFIGURATION COUCHDBCLIENTCONFIGURATION SQSCLIENTCONFIGURATION; do
    [ "$(getVar "$appEnv" "${prefix}_BASICAUTHUSERNAME")" == "$couchUser" ] || return 1
    [ "$(getVar "$appEnv" "${prefix}_BASICAUTHPASSWORD")" == "$couchPass" ] || return 1
  done
}

# Config of the PostgreSQL database and RabbitMQ broker the backend used before it moved its state into
# CouchDB (aam-services #211 and #221). The current backend has no binding for these keys at all, so they
# are inert rather than harmful - but they describe containers the canonical docker-compose.yml no longer
# deploys, so leaving them in place makes the config read as if it still had a database of its own.
LEGACY_STORAGE_KEYS=(
  SPRING_DATASOURCE_URL
  SPRING_DATASOURCE_USERNAME
  SPRING_DATASOURCE_PASSWORD
  SPRING_RABBITMQ_HOST
  SPRING_RABBITMQ_VIRTUALHOST
  SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_ENABLED
  SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_MAXATTEMPTS
)

# Drop the dead PostgreSQL/RabbitMQ config. Args: application.env
removeLegacyStorageConfig() {
  local appEnv="$1" key
  for key in "${LEGACY_STORAGE_KEYS[@]}"; do
    removeEnv "$key" "$appEnv" || return 1
  done
}

# Whether removeLegacyStorageConfig would change nothing - including on an instance still pinned to a
# backend that reads these keys, where removing them would be the breaking change rather than the fix:
# before $COMPOSE_REQUIRES_BACKEND_MAJOR the datasource URL has no default outside the
# local-development profile, so without it the backend fails to start the next time it is recreated.
# Args: application.env, instance .env
legacyStorageConfigRemoved() {
  local appEnv="$1" envFile="$2" key major
  major=$(versionMajor "$(getVar "$envFile" AAM_BACKEND_SERVICE_VERSION)") \
    && [ "$major" -lt "$COMPOSE_REQUIRES_BACKEND_MAJOR" ] && return 0
  for key in "${LEGACY_STORAGE_KEYS[@]}"; do
    ! grep -q "^$key=" "$appEnv" 2>/dev/null || return 1
  done
}

# Point replication-backend's permission checks at the aam-backend client (an existing placeholder like
# NOT_USED as client id is corrected). Args: instance .env, aam-backend client secret
writeReplicationBackendKeycloakClient() {
  local envFile="$1" secret="$2"
  ensureRealValue REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID "aam-backend" "$envFile" || return 1
  upsertEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$secret" "$envFile" || return 1
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
# A repair whose precondition fails (e.g. the instance's realm is not on this Keycloak) is reported and
# skipped; the others still run, and the function returns 1.
# Uses the globals path, org, appEnv and envFile.
repairBackendConfig() {
  local failed=false

  # what is out of date
  local fixKeycloakAdmin=false fixReplicationClient=false fixCouchdbCredentials=false fixRenderApi=false
  local fixLegacyStorage=false
  couchdbClientCredentialsUpToDate "$appEnv" "$envFile" "$path" || fixCouchdbCredentials=true
  renderApiConfigUpToDate "$appEnv" || fixRenderApi=true
  legacyStorageConfigRemoved "$appEnv" "$envFile" || fixLegacyStorage=true
  # the aam-backend client lives in the instance's realm, which must be on the central Keycloak
  if ! requireCentralKeycloak "$envFile"; then
    failed=true
  elif [ "$(getKeycloakRealmStatus "$org")" != "200" ]; then
    echo "ERROR: Realm '$org' not accessible on $KEYCLOAK_HOST. Check the realm exists (and matches INSTANCE_NAME)."
    failed=true
  else
    local keycloakSecret
    keycloakSecret=$(getKeycloakBackendClientSecret "$org")
    if [ -z "$keycloakSecret" ] \
      || isPlaceholderValue "$(getVar "$appEnv" KEYCLOAK_SERVERURL)" \
      || [ "$(getVar "$appEnv" KEYCLOAK_REALM)" != "$org" ] \
      || [ "$(getVar "$appEnv" KEYCLOAK_CLIENTID)" != "aam-backend" ] \
      || [ "$(getVar "$appEnv" KEYCLOAK_CLIENTSECRET)" != "$keycloakSecret" ] \
      || ! serviceAccountHasRealmManagementRole "$org" "${AAM_BACKEND_REALM_MANAGEMENT_ROLES[@]}"; then
      fixKeycloakAdmin=true
    fi
    if [ -z "$keycloakSecret" ] \
      || isPlaceholderValue "$(getVar "$envFile" REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID)" \
      || [ "$(getVar "$envFile" REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET)" != "$keycloakSecret" ]; then
      fixReplicationClient=true
    fi
  fi

  local repairs=()
  $fixKeycloakAdmin && repairs+=(keycloak-admin)
  $fixReplicationClient && repairs+=(replication-backend-client)
  $fixCouchdbCredentials && repairs+=(couchdb-credentials)
  $fixRenderApi && repairs+=(render-api)
  $fixLegacyStorage && repairs+=(legacy-storage-config)
  if [ "${#repairs[@]}" -eq 0 ]; then
    if $failed; then
      return 1
    fi
    echo "Backend already enabled for '$org' and its config is up to date. Nothing to do."
    return 0
  fi
  echo "Backend already enabled for '$org'. Repairing: ${repairs[*]}"

  # Keycloak first, so a failure does not leave a config pointing at a client without the needed access.
  local backendSecret="" carboneSecret=""
  if $fixKeycloakAdmin || $fixReplicationClient; then
    if ! backendSecret=$(ensureKeycloakBackendClient "$org"); then
      echo "ERROR: Could not set up the aam-backend Keycloak client for '$org'."
      fixKeycloakAdmin=false fixReplicationClient=false failed=true
    fi
  fi
  if $fixRenderApi; then
    if ! checkCarbonePrerequisites || ! carboneSecret=$(ensureCarboneRenderClient "$CARBONE_REALM" "carbone-${org}"); then
      echo "ERROR: Could not set up the Carbone render client for '$org'."
      fixRenderApi=false failed=true
    fi
  fi

  local servicesToRecreate=() writeFailed=false
  if $fixKeycloakAdmin || $fixCouchdbCredentials || $fixRenderApi || $fixLegacyStorage; then
    saveRollbackCopy "$appEnv"
  fi
  # Only the repairs that change config the running backend actually reads recreate it. Dropping the
  # legacy PostgreSQL/RabbitMQ keys doesn't: the current backend has no binding for them, so on its own
  # that repair would restart every backend instance for a value nothing reads.
  if $fixKeycloakAdmin || $fixCouchdbCredentials || $fixRenderApi; then
    servicesToRecreate+=("aam-backend-service")
  fi
  if $fixKeycloakAdmin; then
    ensureBackendKeycloakAdminConfig "$appEnv" "https://$KEYCLOAK_HOST" "$org" "$backendSecret" || writeFailed=true
  fi
  if $fixCouchdbCredentials; then
    writeCouchdbClientCredentials "$appEnv" "$envFile" "$path" || writeFailed=true
  fi
  if $fixRenderApi; then
    writeRenderApiConfig "$appEnv" "carbone-${org}" "$carboneSecret" || writeFailed=true
  fi
  if $fixLegacyStorage; then
    removeLegacyStorageConfig "$appEnv" || writeFailed=true
  fi
  if $fixReplicationClient; then
    saveRollbackCopy "$envFile"
    writeReplicationBackendKeycloakClient "$envFile" "$backendSecret" || writeFailed=true
    servicesToRecreate+=("replication-backend")
  fi
  # a partly written config must not be loaded: leave the services running on their old config
  if $writeFailed; then
    echo "ERROR: Could not write the backend config of '$org'. Not recreating ${servicesToRecreate[*]}."
    echo "       Fix the cause and re-run, or restore the rollback copies next to $appEnv / $envFile."
    return 1
  fi

  if [ "${#servicesToRecreate[@]}" -gt 0 ] \
    && ! skipRestartNote "docker compose up -d --force-recreate ${servicesToRecreate[*]}" "$path"; then
    # force-recreate: also when only the role changed, the backend must restart to run its startup provisioning
    if ! (cd "$path" && docker compose up -d --force-recreate "${servicesToRecreate[@]}"); then
      echo "ERROR: Failed to recreate ${servicesToRecreate[*]} for '$org'. Recreate it manually to apply the repair."
      return 1
    fi
  fi
  if $failed; then
    echo "Backend config of '$org' only partly repaired (see the errors above)."
    return 1
  fi
  echo "Backend config repaired: ${repairs[*]}."
}

##############################
# input
##############################

requireInstance "${1:-}"
appEnv="$path/config/aam-backend-service/application.env"
envFile="$path/.env"

# Checked before any config is required, so a fleet-wide --repair-only run doesn't need Keycloak
# credentials for the instances it skips. A half-enabled backend (only one of the two true) is not
# skipped: it needs the manual look the checks further down ask for.
if [ "$repairOnly" = true ] && ! backendEnabledCheck && ! isBackendConfigCreated; then
  echo "Backend not enabled for '$org', skipping (--repair-only)."
  exit 0
fi

requireConfig KEYCLOAK_HOST
requireConfig KEYCLOAK_PASSWORD
requireConfig KEYCLOAK_USER
if ! getKeycloakToken; then
  echo "ERROR: Failed to authenticate with Keycloak. Abort."
  exit 1
fi

if backendEnabledCheck && isBackendConfigCreated; then
  repairBackendConfig
  exit $?
fi

##############################
# enable the backend
##############################

# a half-enabled backend needs a manual look: this script only sets it up from scratch or repairs a complete one
if backendEnabledCheck; then
  echo "Backend already enabled for '$org' (COMPOSE_PROFILES), but it has no $appEnv. Abort."
  exit 1
fi
if isBackendConfigCreated; then
  echo "Backend config already created for '$org' ($appEnv), but the backend is not enabled in COMPOSE_PROFILES. Abort."
  exit 1
fi
if ! replicationBackendEnabledCheck; then
  # all functionality should be the same with a direct CouchDB without replication-backend. However, some URLs will need to be adapted for this scenario
  echo "Replication Backend is required for backend. Please enable first. Abort."
  exit 1
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

requireConfig SENTRY_AUTH_TOKEN
requireConfig SENTRY_DSN_BACKEND
requireCentralKeycloak "$envFile" || exit 1
checkCarbonePrerequisites || exit 1

# Everything that can fail happens before the instance is stopped: the latest config template (from the
# aam-services repository), and the Keycloak clients (both idempotent, so a re-run after a failure is fine).
backendVersion=$(getLatestBackendVersion)
echo "Latest backendVersion available: $backendVersion"
# A release older than the canonical docker-compose.yml supports cannot be enabled with it: it would start
# without containers it still expects. Checked before anything is written, so the instance is left as it was.
if ! backendMajor=$(versionMajor "$backendVersion") \
  || [ "$backendMajor" -lt "$COMPOSE_REQUIRES_BACKEND_MAJOR" ]; then
  echo "ERROR: the latest aam-backend-service release ('$backendVersion') is not a"
  echo "  ${COMPOSE_REQUIRES_BACKEND_MAJOR}.x release, which this docker-compose.yml needs. Abort."
  exit 1
fi
template=$(downloadBackendConfigTemplate "$backendVersion") || exit 1

carboneClientId="carbone-${org}"
if ! carboneSecret=$(ensureCarboneRenderClient "$CARBONE_REALM" "$carboneClientId"); then
  echo "ERROR: Could not set up the Carbone render client for '$org'. Abort."
  exit 1
fi
# the aam-backend client: replication-backend's permission checks and the backend's Keycloak admin access
# (e.g. provisioning the client scopes of its API)
if ! backendSecret=$(ensureKeycloakBackendClient "$org"); then
  echo "ERROR: Could not set up the aam-backend Keycloak client for '$org'. Abort."
  exit 1
fi

# Take the stack down while its config is rewritten, so it comes back up on the new config. With
# --skip-restart the caller restarts it itself (`down && up -d`), so leave it running rather than
# handing back a stopped instance.
if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose down)
fi

saveRollbackCopy "$envFile"
envRollbackCopy="$ROLLBACK_COPY"

# Abort on a failed config write, before CouchDB is locked down or the stack started on a partial config.
abortConfigWrite() {
  echo "ERROR: Could not write the backend config of '$org'. Abort."
  [ -z "$envRollbackCopy" ] || echo "       Restore $envFile from $(basename "$envRollbackCopy") before starting it again."
  [ "$skipRestart" = true ] || echo "       The instance '$org' is stopped - bring it up again with 'docker compose up -d' in $path."
  exit 1
}

setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$envFile" || abortConfigWrite
mkdir -p "$(dirname "$appEnv")" && printf '%s\n' "$template" > "$appEnv" || abortConfigWrite
setEnv CRYPTO_CONFIGURATION_SECRET "$(generate_password)" "$appEnv" || abortConfigWrite
setEnv SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI "https://$KEYCLOAK_HOST/realms/$org" "$appEnv" || abortConfigWrite
writeCouchdbClientCredentials "$appEnv" "$envFile" "$path" || abortConfigWrite
removeLegacyStorageConfig "$appEnv" || abortConfigWrite
writeRenderApiConfig "$appEnv" "$carboneClientId" "$carboneSecret" || abortConfigWrite
setEnv SENTRY_AUTH_TOKEN "$SENTRY_AUTH_TOKEN" "$appEnv" || abortConfigWrite
setEnv SENTRY_DSN "$SENTRY_DSN_BACKEND" "$appEnv" || abortConfigWrite
setEnv SENTRY_SERVER_NAME "$org.$DOMAIN" "$appEnv" || abortConfigWrite
ensureBackendKeycloakAdminConfig "$appEnv" "https://$KEYCLOAK_HOST" "$org" "$backendSecret" || abortConfigWrite

writeReplicationBackendKeycloakClient "$envFile" "$backendSecret" || abortConfigWrite
setEnv COMPOSE_PROFILES "full-stack" "$envFile" || abortConfigWrite
# the app container's /db now needs to reach replication-backend instead of CouchDB directly
upsertEnv DB_ENTRYPOINT_URL "http://${org}-replication-backend:5984" "$envFile" || abortConfigWrite
# ...and its /api now needs to reach aam-backend-service, which this profile also deploys
upsertEnv API_BACKEND_URL "http://${org}-aam-backend-service:8080" "$envFile" || abortConfigWrite

# ensure CouchDB is locked down for replication-backend (admin-only _security, no JWT auth, no anonymous access)
if ! "$scriptDir/create-couchdb.sh" "$path" --with-permissions ${skipRestartArg[@]+"${skipRestartArg[@]}"}; then
  echo "ERROR: Failed to lock down CouchDB for '$org'. Fix it and re-run create-couchdb.sh before starting the stack."
  exit 1
fi

if ! skipRestartNote "docker compose down && docker compose up -d" "$path"; then
  if ! (cd "$path" && docker compose up -d); then
    echo "ERROR: Failed to start '$org' with the backend. Check 'docker compose logs' in $path."
    exit 1
  fi
fi

echo "Backend enabled."
