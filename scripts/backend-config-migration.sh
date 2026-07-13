#!/bin/bash

# This script will migrate the current backend config to the latest template.
# A backup file is created. Existing backups will be overwritten.
#
# How to use
#
# ./backend-config-migration.sh <instance>
# example: ./backend-config-migration.sh qm
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

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
# script
##############################

backendVersion=$(getLatestBackendVersion)
echo "Latest backendVersion available: $backendVersion"

# check if backend is already enabled for this instance
if ! isBackendConfigCreated; then
  echo "No backend config found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
fi

(cd "$path" && docker compose down)

# set aam-backend-service-version to supported version
setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

# backup current config
cp "$path/config/aam-backend-service/application.env" "$path/config/aam-backend-service/application.env_backup"

# copy latest template config (from aam-services repository)
curl -L -o "$path/config/aam-backend-service/application.env" "https://raw.githubusercontent.com/Aam-Digital/aam-services/refs/tags/aam-backend-service/$backendVersion/templates/aam-backend-service/application.template.env"

# migrate values from backend to template if value is still part of the template

# check if .env files end on empty line and adds it if not
if [ "$(tail -c 1 "$path/config/aam-backend-service/application.env_backup")" != $'\n' ]; then
    echo "" >> "$path/config/aam-backend-service/application.env_backup"
    echo "Empty line added to .env file."
fi

# read backup file and check, if key is still part of the template
while IFS='=' read -r key value; do
    # remove spaces
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    # check, if key still exist in new template file
    if grep -q "$key" "$path/config/aam-backend-service/application.env"; then
      setEnv "$key" "$value" "$path/config/aam-backend-service/application.env"
    else
      echo "Der Key '$key' mit dem Wert '$value' existiert NICHT mehr im template. Wert wird nicht übertragen."
    fi
done < "$path/config/aam-backend-service/application.env_backup" # backup file

(cd "$path" && docker compose up -d)

echo "Backend config migration complete."
