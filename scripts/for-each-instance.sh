#!/bin/bash
# Run a command for every instance ($baseDirectory/$PREFIX* folders with a docker-compose.yml), each as its
# own process, and list the instances it failed for. A failure does not stop the remaining instances.
#
# Usage:
#   ./for-each-instance.sh [--only replication-backend|backend] [--in-dir] [--] <command> [args...]
#
# By default the instance directory is appended as the last argument, which fits every script taking an
# <instance> argument:
#   ./for-each-instance.sh --only replication-backend ./create-couchdb.sh
#   ./for-each-instance.sh --only backend ./enable-backend.sh
#   ./for-each-instance.sh ./update-version.sh ndb-core 3.5.0 3.6.0
#
# --only replication-backend   only instances whose COMPOSE_PROFILES deploys replication-backend
# --only backend               only instances whose COMPOSE_PROFILES deploys aam-backend-service
# --in-dir                     run the command inside each instance directory instead (nothing appended):
#                                ./for-each-instance.sh --in-dir docker compose pull
#
# Can be run from any directory.

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

only=""
inDir=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      case "${2:-}" in
        replication-backend | backend) only="$2" ;;
        *) echo "ERROR: --only takes 'replication-backend' or 'backend' (got: '${2:-}')."; usage ;;
      esac
      shift 2
      ;;
    --in-dir) inDir=true; shift ;;
    -h | --help) usage ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown option '$1' (put the command after '--' if it starts with '-')."; usage ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || usage

# A relative command path (e.g. ./create-couchdb.sh) must still resolve after changing into an instance dir.
if [[ "$1" == */* ]] && [ -e "$1" ]; then
  set -- "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" "${@:2}"
fi

runForInstance() {
  local dir="$1" name
  name=$(basename "$dir")
  if [ ! -f "$dir/docker-compose.yml" ]; then
    echo "[$name] no docker-compose.yml, skipping"
    return 0
  fi
  local profile
  profile=$(getVar "$dir/.env" COMPOSE_PROFILES)
  if [ "$only" = replication-backend ] && ! profileDeploysReplicationBackend "$profile"; then
    echo "[$name] no replication-backend (COMPOSE_PROFILES=${profile:-<unset>}), skipping"
    return 0
  fi
  if [ "$only" = backend ] && ! profileDeploysBackend "$profile"; then
    echo "[$name] no aam-backend-service (COMPOSE_PROFILES=${profile:-<unset>}), skipping"
    return 0
  fi

  echo "[$name]"
  local rc=0
  if [ "$inDir" = true ]; then
    (cd "$dir" && "${cmd[@]}") || rc=$?
  else
    ("${cmd[@]}" "$dir") || rc=$?
  fi
  [ "$rc" -eq 0 ] || failed+=("$name")
  echo ""
}

cmd=("$@")
failed=()
forEachInstance runForInstance || exit 1

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Failed for: ${failed[*]}"
  exit 1
fi
