#!/bin/bash

# This script applies sub-folders of the /assets from a baseConfig to an instance,
# including the adjustment to docker-compose.yml to add volumes.

# how to use
# ./enable-assets-overwrites.sh <instance> <baseConfig>
# example: ./enable-assets-overwrites.sh my-system basic

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"

##############################
# ask for input data
##############################

if [ -n "$1" ]; then
  instance="$1"
else
  echo "What is the name of the instance?"
  read -r instance
fi

if [ -n "$2" ]; then
  baseConfig="$2"
else
  echo "What baseConfig should be applied?"
  read -r baseConfig
fi

##############################
# script
##############################

# if $instance not starts with $PREFIX, add it
if [[ ! "$instance" =~ ^$PREFIX ]]; then
  instancePath="$baseDirectory/$PREFIX$instance"
else
  instancePath="$baseDirectory/$instance"
fi

# abort if no assets folder for baseConfig exists
baseConfigPath="$ndbSetupDir/baseConfigs/$baseConfig"
if [ ! -d "$baseConfigPath/assets" ]; then
  echo "No assets folder found for baseConfig '$baseConfig'. Abort."
  exit 1
fi

cp "$instancePath/docker-compose.yml" "$instancePath/docker-compose.yml.bak"

# copy assets from baseConfig to instance
if [ -d "$instancePath/assets" ]; then
  echo "Moving existing assets folder to backup."
  mv "$instancePath/assets" "$instancePath/assets.bak"
  # remove any volume mounts for the existing assets folder in docker-compose.yml
  sed -i '/assets\/.*:\/usr\/share\/nginx\/html\/assets/d' "$instancePath/docker-compose.yml"
fi
cp -r "$baseConfigPath/assets" "$instancePath/assets"

# add one volume mount to docker-compose.yml for each asset present in the assets folder
ensureAssetVolumeMountsFromDir "$instancePath/docker-compose.yml" "$instancePath/assets"

# restart docker if a third arg ($3) is "y" or "true"
if [ "$3" == "y" ] || [ "$3" == "true" ]; then
  docker compose -f "$instance/docker-compose.yml" down && docker compose  -f "$instance/docker-compose.yml" up -d
fi