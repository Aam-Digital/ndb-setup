#!/bin/bash

# This script enable a specific feature for an instance.
# All needed credentials are loaded from the Bitwarden Secrets Manager

# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./set-backend-features.sh <instance> <feature-name> <enable/disable>
# example: ./set-backend-features.sh qm notification enable

source "../setup.env"

# check if BWS_ACCESS_TOKEN is set
if [[ -z "${BWS_ACCESS_TOKEN}" ]]; then
  echo "BWS_ACCESS_TOKEN is not set. Abort."
  exit 1
fi

# set server-base to EU instance
bws config server-base https://vault.bitwarden.eu

##########

if [ -n "$1" ]; then
  instance="$1"
else
  echo "What is the name of the instance?"
  read -r instance
fi

#if [ -n "$2" ]; then
#  featureName="$2"
#else
#  echo "What is the name of the feature? [export, notification]"
#  read -r featureName
#fi
#
#if [ -n "$3" ]; then
#  action="$3"
#else
#  echo "Should the feature enabled or disabled? [enable, disable]"
#  read -r action
#fi

##########

path="../../$PREFIX$instance"
isBackendEnabled=0

backendEnabledCheck() {
  if [ ! -f "$path/config/aam-backend-service/application.env" ]; then
    isBackendEnabled=0
  else
    isBackendEnabled=1
  fi
}

#enableNotification() {
#  # todo
#}

##########

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


# Überprüfen, ob die .env-Datei bereits mit einer Leerzeile endet
if [ "$(tail -c 1 "$path/config/aam-backend-service/application.env_backup")" != $'\n' ]; then
    # Falls nicht, eine Leerzeile hinzufügen
    echo "" >> "$path/config/aam-backend-service/application.env_backup"
    echo "Eine Leerzeile wurde am Ende der Datei hinzugefügt."
else
    echo "Die Datei endet bereits mit einer Leerzeile."
fi

## read backup file and check, if key is still part of the template
while IFS='=' read -r key value; do
    # Entferne mögliche Leerzeichen am Anfang und Ende
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    # Überprüfen, ob der Wert (value) in der anderen Datei (check_file) vorkommt
    if grep -q "$key" "$path/config/aam-backend-service/application.env"; then
        sed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # linux
#        gsed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # macos
    else
        echo "Der Key '$key' mit dem Wert '$value' existiert NICHT mehr im template. Wert wird nicht übertragen"
    fi
done < "$path/config/aam-backend-service/application.env_backup" # backup file

## todo check for empty values in new template file and ask for filling

# 5. enable feature



# 6. set feature specific values

# 7. remove backup

# restart service
