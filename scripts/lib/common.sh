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

# Set a variable in a file, appending it if it does not already exist
upsertEnv() {
  local key="$1"
  local value="$2"
  local file="$3"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
  if ! grep -q "^$key=" "$file" 2>/dev/null; then
    echo "$key=$value" >> "$file"
    echo "  + added $key to $(basename "$file")"
  else
    sed -i "s|^$key=.*|$key=$escaped|g" "$file"
    echo "  ~ updated $key in $(basename "$file")"
  fi
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

# Recognize "unset" placeholder values that older/hand-edited instances may still carry instead of a
# real value (e.g. a Keycloak client ID left as NOT_USED on systems provisioned before it was needed).
# These must be treated like an empty value so callers replace them with the correct one.
# Returns 0 (true) if the value is empty or a known placeholder, 1 (false) otherwise.
isPlaceholderValue() {
  local value="$1"
  # strip surrounding quotes for the comparison (values in .env are sometimes quoted)
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  case "${value,,}" in
    "" | not_used | notused | not-used | "not used" | changeme | change_me | placeholder | todo | tbd | none | unset | "n/a" | na)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Ensure a key is set to $value, but only overwrite when the current value is missing or a placeholder
# (see isPlaceholderValue). An existing real value is preserved. Use this for fields that have a known
# correct value (e.g. the fixed "aam-backend" Keycloak client ID) which some instances still hold as
# NOT_USED — unlike ensureEnv (which keeps any existing value) or setEnv/upsertEnv (which always overwrite).
ensureRealValue() {
  local key="$1"
  local value="$2"
  local file="$3"
  local current
  current=$(getVar "$file" "$key")
  if isPlaceholderValue "$current"; then
    if [ -n "$current" ]; then
      echo "  ! $key is a placeholder ('$current') in $(basename "$file") — replacing with '$value'"
    fi
    upsertEnv "$key" "$value" "$file"
  else
    echo "  = $key already set to '$current' in $(basename "$file"), keeping it"
  fi
}

# Remove a variable from a file. No-op if the key is absent.
removeEnv() {
  local key="$1"
  local file="$2"
  if grep -q "^$key=" "$file" 2>/dev/null; then
    sed -i "/^$key=/d" "$file"
    echo "  - removed $key from $(basename "$file")"
  fi
}

# Remove a variable from a file only when it currently holds exactly $value. Use to drop config that is
# now provided/overridden elsewhere (e.g. by docker-compose) while preserving any custom override.
removeEnvIfValue() {
  local key="$1"
  local value="$2"
  local file="$3"
  if [ "$(getVar "$file" "$key")" == "$value" ]; then
    removeEnv "$key" "$file"
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
# Bitwarden Secrets Manager helpers
##############################

# Look up a Bitwarden Secrets Manager secret by its key/name and print its value to stdout.
# bws's `secret get` only accepts a UUID, so this lists the accessible secrets and filters by key.
# The key must be unique among the secrets the token can read; if several match, the first wins.
# Requires: BWS_ACCESS_TOKEN set and `bws config server-base` already pointed at the right vault.
# Returns: non-zero (and prints nothing) if no secret with that key is found.
getBwsSecretByKey() {
  local key="$1"
  local value
  value=$(bws secret list -t "$BWS_ACCESS_TOKEN" 2>/dev/null | jq -r --arg k "$key" 'map(select(.key == $k)) | .[0].value // empty')
  if [[ -z "$value" ]]; then
    return 1
  fi
  printf '%s' "$value"
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

# Mount every asset present in an instance's assets/ directory into its docker-compose.yml
# (idempotent, via ensureAssetVolumeMount). The filesystem is the source of truth: whatever
# sub-folders/files exist under assets/ get a volume mount.
# The assets/base-configs folder is special-cased — each of its top-level entries is mounted
# individually so base-configs can be overridden per item.
# Arguments:
#   $1 - composeFile: path to the docker-compose.yml
#   $2 - assetsDir:   path to the instance's assets/ directory (no-op if it does not exist)
ensureAssetVolumeMountsFromDir() {
  local composeFile="$1"
  local assetsDir="$2"
  [ -d "$assetsDir" ] || return 0

  local subfolder subfolderName item itemName
  for subfolder in "$assetsDir"/*; do
    [ -e "$subfolder" ] || continue   # skip if the glob did not match anything
    subfolderName=$(basename "$subfolder")

    if [ "$subfolderName" == "base-configs" ] && [ -d "$subfolder" ]; then
      for item in "$subfolder"/*; do
        [ -e "$item" ] || continue
        itemName=$(basename "$item")
        ensureAssetVolumeMount "$composeFile" "base-configs/$itemName"
      done
    else
      ensureAssetVolumeMount "$composeFile" "$subfolderName"
    fi
  done
}

##############################
# Organisation name validation
##############################

# Validate an organisation name against the naming contract shared by directory names, DNS labels,
# Docker container/network names, and Keycloak realm names: non-empty, lowercase letters/digits/hyphens
# only, must not start or end with a hyphen.
# Returns 0 (true) if valid, 1 (false) otherwise.
isValidOrgName() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

##############################
# Instance path resolution
##############################

# Resolve the instance directory from either a name or a path, and set the global `path` (absolute).
# The first argument is treated as:
#   - a PATH to the instance directory when it is "." or contains a "/" (e.g. ".", "./c-acme",
#     "/var/docker/c-acme") — used as-is, so scripts can run against any location without a fixed layout
#   - otherwise an instance NAME, resolved to "$baseDirectory/$PREFIX<name>" (the standard layout)
# For the path form the directory must already exist. For the name form it may not (callers that create
# the instance handle that themselves). Requires baseDirectory + PREFIX for the name form.
resolveInstancePath() {
  local arg="$1"
  case "$arg" in
    . | */*)
      path="$(cd "$arg" 2>/dev/null && pwd)"
      if [ -z "$path" ]; then
        echo "ERROR: instance directory not found: $arg" >&2
        return 1
      fi
      ;;
    *)
      local name
      name=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
      name="${name#"$PREFIX"}"   # tolerate the PREFIX being included in the name or not
      path="$baseDirectory/$PREFIX$name"
      ;;
  esac
}

##############################
# Instance iteration
##############################

# Run a callback for one or all instances.
# Usage: forEachInstance <callback> [instance]
#   <callback>  name of a function; called once per instance with the absolute
#               instance directory as its first argument
#   [instance]  optional single instance — an instance NAME (with or without the PREFIX) or a PATH to
#               the instance directory (incl. "."); see resolveInstancePath. When omitted, iterates
#               every "$baseDirectory/${PREFIX}*" directory.
# Requires: $baseDirectory and $PREFIX set (from setup.env).
# Returns: non-zero if a named instance is missing or PREFIX is unset.
forEachInstance() {
  local callback="$1"
  local single="${2:-}"

  if [ -n "$single" ]; then
    # single instance mode: resolve a name or a path, then capture into a local so callbacks that use a
    # global `path` are not affected by resolveInstancePath writing to the global `path`.
    resolveInstancePath "$single" || return 1
    local dir="$path"
    if [ ! -d "$dir" ]; then
      echo "Instance directory not found: $dir"
      return 1
    fi
    "$callback" "$dir"
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
