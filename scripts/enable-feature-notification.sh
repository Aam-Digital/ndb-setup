#!/bin/bash

# This script will enable the notification feature for an customer instance.

# how to use
# ./enable-feature-notification.sh <instance>
# example: ./enable-feature-notification.sh qm
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#

##############################
# setup
##############################

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
# variables
##############################

path="../../$PREFIX$instance"
isBackendEnabled=0

##############################
# functions
##############################

backendEnabledCheck() {
  if [ ! -f "$path/config/aam-backend-service/application.env" ]; then
    isBackendEnabled=0
  else
    isBackendEnabled=1
  fi
}

setEnv() {
    local key="$1"
    local value="$2"

    sed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # linux
    # gsed -i "s|^$key=.*|$key=$value|g" "$path/config/aam-backend-service/application.env" # macos
}

# Funktion zum Abrufen der Umgebungsvariablen
getVar() {
    local file="$1"
    local var="$2"
    local value

    # grep sucht die Zeile mit der Variable, cut extrahiert den Wert
    value=$(grep "^$var=" "$file" | cut -d '=' -f2-)

    # Falls die Variable nicht existiert oder leer ist, eine Meldung ausgeben
    if [ -z "$value" ]; then
      value="n/a"
    fi

    echo "$value"
}

##############################
# script
##############################

# check if backend is already enabled for this instance
backendEnabledCheck

if [ "$isBackendEnabled" == 0 ]; then
  echo "No backend found for instance '$instance'. Please run './enable-backend.sh' first."
  exit 1
else
  echo ""
fi

isFeatureAlreadyEnabled=$(getVar "$path/config/aam-backend-service/application.env" FEATURES_NOTIFICATIONAPI_ENABLED)

if [ "$isFeatureAlreadyEnabled" == "true" ]; then
  echo "Feature is already enabled for this instance. Abort."
  exit 1
else
  echo ""
fi

if [ -n "$2" ]; then
  configCredentialBase64="$2"
else
  echo "Insert value for NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64:"
  read -r configCredentialBase64
fi

setEnv "NOTIFICATIONFIREBASECONFIGURATION_CREDENTIALFILEBASE64" "$configCredentialBase64"

if [ -n "$2" ]; then
  linkBaseUrl="$2"
else
  echo "Insert value for NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL: (e.g. https://<instance>.aam-digital.app)"
  read -r linkBaseUrl
fi

setEnv "NOTIFICATIONFIREBASECONFIGURATION_LINKBASEURL" "$linkBaseUrl"
setEnv "FEATURES_NOTIFICATIONAPI_MODE" "firebase"
setEnv "FEATURES_NOTIFICATIONAPI_ENABLED" "true"

echo "Feature enabled. Please restart the service."
