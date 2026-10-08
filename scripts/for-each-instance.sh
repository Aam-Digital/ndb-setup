#!/bin/bash
usage() {
  cat <<'EOF'
Run a command for every instance ($PREFIX* folders with a docker-compose.yml next to ndb-setup), each in its
own process inside the instance folder, and list the instances it failed for. A failure doesn't stop the
remaining instances.

Usage:
  ./for-each-instance.sh [--only replication-backend|backend] [--] <command> [args...]

  --only replication-backend  only instances whose COMPOSE_PROFILES deploys replication-backend
  --only backend              only instances whose COMPOSE_PROFILES deploys aam-backend-service

How the command runs:
  a script path (contains "/"): gets the instance folder as its first argument, before [args...]
      ./for-each-instance.sh --only backend ./enable-backend.sh
      ./for-each-instance.sh ./update-version.sh ndb-core 3.5.0 3.6.0   # runs update-version.sh <dir> ndb-core ...
  any other command: runs as given
      ./for-each-instance.sh docker compose pull
  one quoted string with spaces: runs with bash, so &&, | and variables work
      ./for-each-instance.sh "docker compose down && docker compose up -d"
      ./for-each-instance.sh 'grep ^APP_VERSION= .env'

Options of for-each-instance.sh go before the command; put the command after "--" if it starts with "-".
EOF
  exit "${1:-1}"
}

# Parse the own options (including -h / --help) before lib/init.sh, which must not take a --help after the
# command: that belongs to the command.
only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      case "${2:-}" in
        replication-backend | backend) only="$2" ;;
        *) echo "ERROR: --only takes 'replication-backend' or 'backend' (got: '${2:-}')."; usage ;;
      esac
      shift 2
      ;;
    -h | --help) usage 0 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown option '$1' (put the command after '--' if it starts with '-')."; usage ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || usage

ownHelpFlag=true
source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"

if [ "$#" -eq 1 ] && [[ "$1" == *[[:space:]]* ]]; then
  mode=shell
else
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: command not found: $1 (relative paths are resolved from the current directory)."
    exit 1
  fi
  if [[ "$1" == */* ]]; then
    mode=script
    # a relative script path (e.g. ./create-couchdb.sh) must still resolve inside the instance directories
    set -- "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" "${@:2}"
  else
    mode=command
  fi
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
  case "$mode" in
    shell) (cd "$dir" && bash -c "${cmd[0]}") || rc=$? ;;
    script) (cd "$dir" && "${cmd[0]}" "$dir" "${cmd[@]:1}") || rc=$? ;;
    command) (cd "$dir" && "${cmd[@]}") || rc=$? ;;
  esac
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
