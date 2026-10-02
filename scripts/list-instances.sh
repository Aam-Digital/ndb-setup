#!/bin/bash
usage() {
  cat <<'EOF'
List all instances as a table: deployment type (COMPOSE_PROFILES), the pinned versions of the app,
replication-backend and aam-backend-service, and which backend features are enabled.

Usage:
  ./list-instances.sh
EOF
  exit "${1:-1}"
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart is accepted (and ignored: this script only reads)
source "$scriptDir/lib/skip-restart.sh"

# one row per instance; "-" for a value that is not set, so the columns stay aligned
printInstanceRow() {
  local dir="$1" appEnv="$1/config/aam-backend-service/application.env" key
  local row=("$(basename "$dir")")
  for key in COMPOSE_PROFILES APP_VERSION AAM_REPLICATION_BACKEND_VERSION AAM_BACKEND_SERVICE_VERSION; do
    row+=("$(getVar "$dir/.env" "$key" -)")
  done
  for key in FEATURES_EXPORTAPI_ENABLED FEATURES_SKILLAPI_MODE FEATURES_NOTIFICATIONAPI_ENABLED DATABASECHANGEDETECTION_ENABLED; do
    row+=("$(getVar "$appEnv" "$key" -)")
  done
  printf '%s\t' "${row[@]}"
  echo
}

{
  echo -e "instance-name\tdeployment-type\tapp-version\treplication-backend\tbackend-version\texport-api\tskilllab-api\tnotification-api\tchange-detection"
  echo -e "-------------\t---------------\t-----------\t-------------------\t---------------\t----------\t------------\t----------------\t----------------"
  forEachInstance printInstanceRow
} | column -t
