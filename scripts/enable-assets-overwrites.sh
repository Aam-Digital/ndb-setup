#!/bin/bash

# This script applies sub-folders of the /assets from a baseConfig to an instance,
# including the adjustment to docker-compose.yml to add volumes.

# how to use
# ./enable-assets-overwrites.sh <instance> <baseConfig>
# example: ./enable-assets-overwrites.sh my-system basic

##############################
# setup
##############################

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

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

instancePath="$baseDirectory/$PREFIX$instance"

# abort if no assets folder for baseConfig exists
baseConfigPath="$baseDirectory/ndb-setup/baseConfigs/$baseConfig"
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

# add one volume mount to docker-compose.yml for each sub-folder in assets
for subfolder in "$instancePath"/assets/*; do
  subfolderName=$(basename "$subfolder")
  volumeMount="- .\/assets\/$subfolderName:\/usr\/share\/nginx\/html\/assets\/$subfolderName"

  echo "Adding volume mount for $subfolderName: $volumeMount"

  # insert the volumeMount line in the docker-compose after the first occurrence of "volumes:"
  sed -i "0,/volumes:/s/volumes:/&\n      $volumeMount/" "$instancePath/docker-compose.yml"
done