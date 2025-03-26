#!/bin/bash

# This script will migrate the current backend config to the latest template.
# A backup file is created. Existing backups will be overwritten.
#
# How to use
#
# ./backend-config-migration.sh <instance>
# example: ./backend-config-migration.sh qm

source "../setup.env"

##############################
# ask for input data
##############################

if [ -n "$1" ]; then
  instance="$1"
else
  echo "What is the name of the instance?"
  read -r instance
fi


##############################
# setup
##############################

path="../../$PREFIX$instance"
isBackendEnabled=0

backendEnabledCheck() {
  if [ ! -f "$path/config/aam-backend-service/application.env" ]; then
    isBackendEnabled=0
  else
    isBackendEnabled=1
  fi
}

##############################
# setup
##############################

# 1. check if backend is already enabled for this instance
backendEnabledCheck

if [ "$isBackendEnabled" == 0 ]; then
  echo "No backend found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
else
  echo ""
fi

# 2. backup current config
cp "$path/config/aam-backend-service/application.env" "$path/config/aam-backend-service/application.env_backup"

# 3. copy template config
cp "../config-templates/application.env.template" "$path/config/aam-backend-service/application.env"

# 4. migrate values from backend to template if value is still part of the template

# check if .env files end on empty line and adds it if not
if [ "$(tail -c 1 "$path/config/aam-backend-service/application.env_backup")" != $'\n' ]; then
    echo "" >> "$path/config/aam-backend-service/application.env_backup"
    echo "Empty line added to .env file."
fi

## read backup file and check, if key is still part of the template
while IFS='=' read -r key value; do
    # remove spaces
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    # check, if key still exist in new template file
    if grep -q "$key" "$path/config/aam-backend-service/application.env"; then
        sed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # linux
#        gsed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # macos
    else
        echo "Der Key '$key' mit dem Wert '$value' existiert NICHT mehr im template. Wert wird nicht übertragen."
    fi
done < "$path/config/aam-backend-service/application.env_backup" # backup file


echo "Backend config migration complete. Please restart the service."
