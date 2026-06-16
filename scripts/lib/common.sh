#!/bin/bash
# Shared utility functions for ndb-setup scripts.
# Source this file in any script that needs these helpers:
#   source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

##############################
# Environment helpers
##############################

# Get a variable value from a .env file
getVar() {
  local file="$1"
  local var="$2"
  local fallback="${3:-}"
  local value

  value=$(grep "^$var=" "$file" 2>/dev/null | cut -d '=' -f2-) || true
  if [[ -z "$value" ]]; then
    echo "$fallback"
  else
    echo "$value"
  fi
}

# Set (replace) a variable in a file (key must already exist)
setEnv() {
  local key="$1"
  local value="$2"
  local file="$3"
  if ! grep -q "^$key=" "$file" 2>/dev/null; then
    echo "  WARNING: $key not found in $(basename "$file"), cannot update (use ensureEnv first)"
    return 1
  fi
  # escape sed special characters in value (\, &, |)
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
  sed -i "s|^$key=.*|$key=$escaped|g" "$file"
  echo "  ~ updated $key in $(basename "$file")"
}

# Append a variable to a file if it does not already exist
ensureEnv() {
  local key="$1"
  local value="$2"
  local file="$3"
  if ! grep -q "^$key=" "$file" 2>/dev/null; then
    echo "$key=$value" >> "$file"
    echo "  + added $key to $(basename "$file")"
  else
    echo "  = $key already exists in $(basename "$file"), skipping"
  fi
}

# Create a timestamped backup of a file.
# Sets the global BACKUP_FILE to the backup path (empty if the source file did not exist) so callers can
# restore from it, e.g. to roll back a failed redeploy.
backupFile() {
  local file="$1"
  local backup="$file.bak-$(date +%Y%m%d%H%M%S)"
  BACKUP_FILE=""
  if [ -f "$file" ]; then
    cp "$file" "$backup"
    BACKUP_FILE="$backup"
    echo "  backup: $(basename "$backup")"
  fi
}

##############################
# Docker compose helpers
##############################

# Ensure a volume mount for an asset sub-path exists in an instance's docker-compose.yml.
# Arguments:
#   $1 - composeFile: path to the docker-compose.yml
#   $2 - itemName:    the asset path (e.g. "icons" or "base-configs/demo")
# Behaviour (idempotent):
#   - if the mount is already active (uncommented)            -> no-op
#   - if a commented placeholder for the mount exists          -> enable it (uncomment)
#   - otherwise                                                -> insert after the first "volumes:"
ensureAssetVolumeMount() {
  local composeFile="$1"
  local itemName="$2"
  local volumeMount="- ./assets/$itemName:/usr/share/nginx/html/assets/$itemName"
  # regex-escaped mount for matching it within the compose file
  local escaped
  escaped=$(printf '%s' "$volumeMount" | sed -e 's/[][\\.^$*]/\\&/g')

  if grep -Eq "^[[:space:]]*${escaped}([[:space:]]|\$)" "$composeFile"; then
    # already enabled as an active (uncommented) mount -> idempotent no-op
    echo "  = volume mount for $itemName already exists, skipping"
  elif grep -Eq "^[[:space:]]*#[[:space:]]*${escaped}([[:space:]]|\$)" "$composeFile"; then
    # a commented placeholder exists -> just enable it (drop the leading '#' and any trailing comment)
    echo "  ~ enabling placeholder volume mount for $itemName"
    sed -i -E "s|^([[:space:]]*)#[[:space:]]*(${escaped})([[:space:]].*)?\$|\\1\\2|" "$composeFile"
  else
    # no placeholder for this item -> insert it after the first occurrence of "volumes:"
    echo "  + adding volume mount for $itemName"
    sed -i "0,/volumes:/s|volumes:|&\\n      $volumeMount|" "$composeFile"
  fi
}

# Print the asset item-names (e.g. "icons", "base-configs/demo") whose volume mounts are
# currently *active* (uncommented) in a docker-compose.yml, one per line.
# Top-level file mounts (config.json etc.) are not under ./assets/ and are excluded.
listActiveAssetMounts() {
  local composeFile="$1"
  grep -E "^[[:space:]]*- \./assets/.+:/usr/share/nginx/html/assets/" "$composeFile" \
    | sed -E "s#^[[:space:]]*- \./assets/(.+):/usr/share/nginx/html/assets/.+#\1#"
}

##############################
# Instance iteration
##############################

# Run a callback for one or all instances.
# Usage: forEachInstance <callback> [instance]
#   <callback>  name of a function; called once per instance with the absolute
#               instance directory as its first argument
#   [instance]  optional single instance (with or without the PREFIX); when
#               omitted, iterates every "$baseDirectory/${PREFIX}*" directory
# Requires: $baseDirectory and $PREFIX set (from setup.env).
# Returns: non-zero if a named instance is missing or PREFIX is unset.
forEachInstance() {
  local callback="$1"
  local single="${2:-}"

  if [ -n "$single" ]; then
    # single instance mode (tolerate the prefix being included or not)
    local path="$baseDirectory/${PREFIX:-}${single#"${PREFIX:-}"}"
    if [ ! -d "$path" ]; then
      echo "Instance directory not found: $path"
      return 1
    fi
    "$callback" "$path"
    return
  fi

  # all instances
  if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set. Aborting to avoid operating on all directories."
    return 1
  fi
  local D
  for D in "$baseDirectory/${PREFIX}"*; do
    [ -d "$D" ] || continue
    "$callback" "$D"
  done
}

##############################
# Backend / instance checks
##############################

# Check if aam-backend-service is enabled (COMPOSE_PROFILES=full-stack).
# Requires: $path set to the instance directory.
# Returns: 0 (true) if enabled, 1 (false) otherwise
backendEnabledCheck() {
  local composeProfiles
  composeProfiles=$(getVar "$path/.env" COMPOSE_PROFILES)
  [ "$composeProfiles" = "full-stack" ]
}

# Check if an application.env config exists for aam-backend-service.
# Requires: $path set to the instance directory.
# Returns: 0 (true) if exists, 1 (false) otherwise
isBackendConfigCreated() {
  [ -f "$path/config/aam-backend-service/application.env" ]
}

# Check if replication-backend is enabled (COMPOSE_PROFILES != database-only).
# Requires: $path set to the instance directory.
# Returns: 0 (true) if enabled, 1 (false) otherwise
replicationBackendEnabledCheck() {
  local composeProfiles
  composeProfiles=$(getVar "$path/.env" COMPOSE_PROFILES)
  [ "$composeProfiles" != "database-only" ]
}

# Fetch the latest aam-backend-service release version from GitHub.
# Prints the version string to stdout.
getLatestBackendVersion() {
  curl -s https://api.github.com/repos/Aam-Digital/aam-services/releases | jq -r 'map(select(.name | test("^aam-backend-service/"))) | .[0].name | split("/") | .[1]'
}

##############################
# Password generation
##############################

_common_chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789

# Generate a random 24-character alphanumeric password.
# Prints the password to stdout.
generate_password() {
  local pw=""
  for _ in {1..24} ; do
    pw="$pw${_common_chars:RANDOM%${#_common_chars}:1}"
  done
  printf '%s' "$pw"
}
