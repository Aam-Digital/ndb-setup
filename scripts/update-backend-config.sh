#!/bin/bash
# Update an instance's aam-backend-service to a release and migrate its application.env to that release's
# config template: keys still in the template keep their current value, new keys get the template default.
# Keys no longer in the template are kept too (and reported), so nothing written by the setup scripts gets
# lost. application.env is backed up first. Since new keys only have the template's defaults, re-run
# ./enable-backend.sh <instance> afterwards to re-apply the instance-specific values (its repair path).
#
# Usage:
#   ./update-backend-config.sh [--version <version>] <instance>
#     --version  the aam-backend-service release (default: the latest one on GitHub). Pass it when running
#                for many instances, to not hit GitHub's API rate limit on each:
#                  ./for-each-instance.sh --only backend ./update-backend-config.sh --version 1.22.15
#
# Can be run from any directory.

set -uo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

backendVersion=""
instanceArg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) backendVersion="${2:-}"; [ -n "$backendVersion" ] || usage; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) [ -z "$instanceArg" ] || usage; instanceArg="$1"; shift ;;
  esac
done
[ -n "$instanceArg" ] || usage

resolveInstancePath "$instanceArg" || exit 1
if [ ! -d "$path" ]; then
  echo "Instance directory not found: $path"
  exit 1
fi
instance=$(basename "$path")
appEnv="$path/config/aam-backend-service/application.env"

if ! isBackendConfigCreated; then
  echo "[$instance] no backend config found. Run './enable-backend.sh' first."
  exit 1
fi

if [ -z "$backendVersion" ]; then
  backendVersion=$(getLatestBackendVersion)
  echo "[$instance] latest aam-backend-service release: $backendVersion"
fi

# everything that can fail happens before the instance's config is touched
template=$(mktemp)
merged=$(mktemp)
trap 'rm -f "$template" "$merged"' EXIT
downloadBackendConfigTemplate "$backendVersion" "$template" || exit 1

# Merge: the template with the current value of each key it still has, then the keys it no longer has.
cp "$template" "$merged"
droppedKeys=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in "" | "#"*) continue ;; esac
  key="${line%%=*}"
  [ "$key" != "$line" ] || continue
  key="${key//[[:space:]]/}"
  value="${line#*=}"
  if grep -q "^$key=" "$merged"; then
    upsertEnv "$key" "$value" "$merged" >/dev/null
  else
    droppedKeys+=("$key")
  fi
done < "$appEnv"
if [ "${#droppedKeys[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# not in the aam-backend-service $backendVersion template, kept from the previous config"
    grep -E "^($(IFS='|'; echo "${droppedKeys[*]}"))=" "$appEnv"
  } >> "$merged"
  echo "[$instance] not in the $backendVersion template anymore, kept (remove them if obsolete): ${droppedKeys[*]}"
fi

backupFile "$appEnv"
cat "$merged" > "$appEnv"
backupFile "$path/.env"
setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

echo "[$instance] redeploying..."
if ! (cd "$path" && docker compose pull && docker compose up -d); then
  echo "[$instance] ERROR: redeploy failed. The previous config is in the backups listed above."
  exit 1
fi
echo "[$instance] aam-backend-service updated to $backendVersion."
