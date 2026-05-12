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
  grep "^$var=" "$file" 2>/dev/null | cut -d '=' -f2- || echo ""
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

# Create a timestamped backup of a file
backupFile() {
  local file="$1"
  local backup="$file.bak-$(date +%Y%m%d%H%M%S)"
  if [ -f "$file" ]; then
    cp "$file" "$backup"
    echo "  backup: $(basename "$backup")"
  fi
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
