#!/bin/bash

# This script will enable the backend for an customer instance.
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
# Requires: CARBONE_HOST set in setup.env (environment-specific):
#   Environment  KEYCLOAK_HOST                  CARBONE_HOST
#   -----------  -----------------------------  --------------------------------
#   Staging      keycloak.aam-digital.net        pdf.dev-cluster.aam-digital.net
#   Production   keycloak.aam-digital.com        pdf.aam-digital.app
#

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/secrets.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

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
[ -n "$instance" ] || instance="${instanceArg#"$PREFIX"}"

##############################
# variables
##############################

# resolve config from setup.env / environment, falling back to Bitwarden when a token is available
requireConfig RENDER_API_CLIENT_ID_DEV
requireConfig RENDER_API_CLIENT_SECRET_DEV
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
setEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHUSERNAME "$(getVar "$path/.env" COUCHDB_USER)" "$path/config/aam-backend-service/application.env"
setEnv AAMREPLICATIONBACKENDCLIENTCONFIGURATION_BASICAUTHPASSWORD "$(getVar "$path/.env" COUCHDB_PASSWORD)" "$path/config/aam-backend-service/application.env"
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
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH "https://$CARBONE_HOST" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID "$RENDER_API_CLIENT_ID_DEV" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET "$RENDER_API_CLIENT_SECRET_DEV" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT "https://auth.aam-digital.dev/realms/aam-digital/protocol/openid-connect/token" "$path/config/aam-backend-service/application.env"
setEnv AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE "client_credentials" "$path/config/aam-backend-service/application.env"
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

# ensure the client ID is set (and correct an existing placeholder like NOT_USED)
ensureRealValue REPLICATION_BACKEND_KEYCLOAK_CLIENT_ID "aam-backend" "$path/.env"

# ensure key exists before setting (older .env templates may lack it)
if ! grep -q '^REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=' "$path/.env"; then
  echo "REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET=" >> "$path/.env"
fi
setEnv REPLICATION_BACKEND_KEYCLOAK_CLIENT_SECRET "$clientSecret" "$path/.env"

setEnv COMPOSE_PROFILES "full-stack" "$path/.env"

if [ "$skipRestart" != "true" ]; then
  (cd "$path" && docker compose up -d)
fi

echo "Backend enabled."
