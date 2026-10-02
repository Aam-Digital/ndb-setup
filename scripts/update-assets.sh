#!/bin/bash
usage() {
  cat <<'EOF'
Replace the assets/ folder of an instance with the one of a baseConfig (baseConfigs/<baseConfig>/assets) and
volume-mount each asset into the app container. The previous folder is kept as "assets.rollback-<timestamp>"
(its firebase-config.json is carried over).

Usage:
  ./update-assets.sh <instance> [baseConfig] [y|true] [--skip-restart]

  baseConfig  asked for if not given
  y | true    restart the instance afterwards (without it, nothing is restarted)
EOF
  exit "${1:-1}"
}

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

##############################
# ask for input data
##############################

requireInstance "${1:-}"

if [ -n "${2:-}" ]; then
  baseConfig="$2"
else
  echo "What baseConfig should be applied?"
  read -r baseConfig
fi

##############################
# script
##############################

# abort if no assets folder for baseConfig exists
baseConfigPath="$ndbSetupDir/baseConfigs/$baseConfig"
if [ ! -d "$baseConfigPath/assets" ]; then
  echo "No assets folder found for baseConfig '$baseConfig'. Abort."
  exit 1
fi

saveRollbackCopy "$path/docker-compose.yml"

# copy assets from baseConfig to instance
assetsCopy=""
if [ -d "$path/assets" ]; then
  assetsCopy="assets.rollback-$(date +%Y%m%d%H%M%S)"
  echo "  rollback copy: $assetsCopy/ (the previous assets folder)"
  mv "$path/assets" "$path/$assetsCopy"
  # remove any volume mounts for the existing assets folder in docker-compose.yml
  sed -i '/assets\/.*:\/usr\/share\/nginx\/html\/assets/d' "$path/docker-compose.yml"
fi
cp -r "$baseConfigPath/assets" "$path/assets"

# Keep the Firebase web config enable-notifications.sh writes to assets/: it is not part of the baseConfig,
# and without it (and its volume mount, re-added below) push notifications stop working.
# Only a regular file: Docker creates a directory there when the mounted file is missing.
if [ -n "$assetsCopy" ] && [ -f "$path/$assetsCopy/firebase-config.json" ]; then
  cp "$path/$assetsCopy/firebase-config.json" "$path/assets/firebase-config.json"
  echo "  kept assets/firebase-config.json (push notifications config)"
fi

# add one volume mount to docker-compose.yml for each asset present in the assets folder
ensureAssetVolumeMountsFromDir "$path/docker-compose.yml" "$path/assets"

# restart docker only if a third arg ($3) asks for it (create-instance.sh calls this before the instance
# exists as a running stack), and never with --skip-restart
if [ "${3:-}" == "y" ] || [ "${3:-}" == "true" ]; then
  if ! skipRestartNote "docker compose up -d" "$path"; then
    (cd "$path" && docker compose up -d)
  fi
fi