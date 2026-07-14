#!/bin/bash
# Print each instance's COMPOSE_PROFILES (deployment type).

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$scriptDir/setup.env"
source "$scriptDir/scripts/lib/common.sh"

getComposeProfiles() {
  local raw_value="$1"

  case "$raw_value" in
      "replication-backend")
          echo "with-permissions"
          ;;
      "replication-backend,aam-backend-service")
          echo "full-stack"
          ;;
      *)
          echo "Unbekannter Wert: $raw_value"
          return 1
          ;;
  esac
}

printInstanceProfiles() {
  local dir="$1"
  local instance_name="${dir##*/}"
  instance_name="${instance_name#"$PREFIX"}"
  local profiles
  profiles=$(getVar "$dir/.env" COMPOSE_PROFILES)
  echo "$instance_name -> $profiles -> $(getComposeProfiles "$profiles")"
}

forEachInstance printInstanceProfiles
