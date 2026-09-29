#!/bin/bash

# This script applies sub-folders of the /assets from a baseConfig to an instance,
# including the adjustment to docker-compose.yml to add volumes.

# how to use
# ./apply-asset-overrides.sh <instance> <baseConfig>
# example: ./apply-asset-overrides.sh my-system basic

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

resolveInstancePath "$instance" || exit 1
instancePath="$path"

# abort if no assets folder for baseConfig exists
baseConfigPath="$ndbSetupDir/baseConfigs/$baseConfig"
if [ ! -d "$baseConfigPath/assets" ]; then
  echo "No assets folder found for baseConfig '$baseConfig'. Abort."
  exit 1
fi

saveRollbackCopy "$instancePath/docker-compose.yml"

# copy assets from baseConfig to instance
if [ -d "$instancePath/assets" ]; then
  assetsCopy="assets.rollback-$(date +%Y%m%d%H%M%S)"
  echo "  rollback copy: $assetsCopy/ (the previous assets folder)"
  mv "$instancePath/assets" "$instancePath/$assetsCopy"
  # remove any volume mounts for the existing assets folder in docker-compose.yml
  sed -i '/assets\/.*:\/usr\/share\/nginx\/html\/assets/d' "$instancePath/docker-compose.yml"
fi
cp -r "$baseConfigPath/assets" "$instancePath/assets"

# add one volume mount to docker-compose.yml for each asset present in the assets folder
ensureAssetVolumeMountsFromDir "$instancePath/docker-compose.yml" "$instancePath/assets"

# restart docker if a third arg ($3) is "y" or "true"
if [ "$3" == "y" ] || [ "$3" == "true" ]; then
  (cd "$instancePath" && docker compose down && docker compose up -d)
fi