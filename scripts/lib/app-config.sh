#!/bin/bash
# Helpers for an instance's config.json, which overrides the app's environment at startup
# (e.g. remoteLoggingDsn). Source it after lib/init.sh. The helpers
# require jq and return non-zero (with an error on stderr) if the file is missing or not a JSON object.

# Print the value of key $2 in config.json $1 (nothing if the key is missing or null).
getAppConfig() {
  jq -r --arg k "$2" 'if type == "object" then .[$k] | select(. != null) else error end' "$1" 2>/dev/null
}

# Whether config.json $1 has key $2 (also with an empty or null value).
hasAppConfig() {
  jq -e --arg k "$2" 'type == "object" and has($k)' "$1" >/dev/null 2>&1
}

# Apply jq filter $2 (with --arg/--argjson options $3...) to config.json $1, in place: the file is bind-mounted
# into the app container on its own, and replacing it (mv) would leave the running container on the old file.
_editAppConfig() {
  local file="$1" filter="$2" out
  shift 2
  if ! out=$(jq -e "$@" "if type == \"object\" then $filter else error(\"not a JSON object\") end" "$file" 2>&1); then
    echo "ERROR: could not update $file: $out" >&2
    return 1
  fi
  printf '%s\n' "$out" > "$file"
}

# Set key $2 to the string $3 in config.json $1.
setAppConfig() {
  _editAppConfig "$1" '.[$k] = $v' --arg k "$2" --arg v "$3"
}

# Remove key $2 from config.json $1.
removeAppConfig() {
  _editAppConfig "$1" 'del(.[$k])' --arg k "$2"
}
