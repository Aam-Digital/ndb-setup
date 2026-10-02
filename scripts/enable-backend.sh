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
# ./enable-backend.sh <instance> [--skip-restart]
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

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

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
  couchdbClientCredentialsUpToDate "$appEnv" "$envFile" "$path" || fixCouchdbCredentials=true
  renderApiConfigUpToDate "$appEnv" || fixRenderApi=true
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
  if $fixKeycloakAdmin || $fixCouchdbCredentials || $fixRenderApi; then
    saveRollbackCopy "$appEnv"
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
setEnv SPRING_DATASOURCE_USERNAME "$(getVar "$envFile" COUCHDB_USER)" "$appEnv" || abortConfigWrite
setEnv SPRING_DATASOURCE_PASSWORD "$(getVar "$envFile" COUCHDB_PASSWORD)" "$appEnv" || abortConfigWrite
writeCouchdbClientCredentials "$appEnv" "$envFile" "$path" || abortConfigWrite
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
