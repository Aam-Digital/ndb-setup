#!/bin/bash
usage() {
  cat <<'EOF'
Update the pinned image version of a service of an instance (APP_VERSION, AAM_REPLICATION_BACKEND_VERSION or
AAM_BACKEND_SERVICE_VERSION in .env) from old_version to new_version, then pull and redeploy. An instance that
is not on old_version is skipped.

Usage:
  ./update-version.sh <instance> <service> <old_version> <new_version> [--skip-restart]

  service         ndb-core | replication-backend | aam-services
  --skip-restart  only update .env; the instance picks the version up on its next
                  'docker compose pull && docker compose up -d'

After raising aam-services, run ./enable-backend.sh for the instance: the Keycloak clients are imported from
the definitions of the release it runs, and a release needing a new permission only gets it that way.

Example: ./update-version.sh acme ndb-core 3.5.0 3.6.0
For all instances: ./for-each-instance.sh ./update-version.sh <service> <old_version> <new_version>
EOF
  exit "${1:-1}"
}

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

positional=()
for arg in "$@"; do
    case "$arg" in
        -*) echo "Unknown option: $arg"; usage ;;
        *)  positional+=("$arg") ;;
    esac
done

if [ "${#positional[@]}" -ne 4 ]; then
    usage
fi

INSTANCE="${positional[0]}"
SERVICE="${positional[1]}"
OLD_VERSION="${positional[2]}"
NEW_VERSION="${positional[3]}"

case "$SERVICE" in
    ndb-core)             VAR="APP_VERSION" ;;
    replication-backend)  VAR="AAM_REPLICATION_BACKEND_VERSION" ;;
    aam-services)         VAR="AAM_BACKEND_SERVICE_VERSION" ;;
    *) echo "Invalid service name. Use ndb-core, replication-backend, aam-services."; exit 1 ;;
esac

update_instance() {
    local D="$1"
    local instance="${D##*/}"
    local envFile="$D/.env"

    if [ ! -f "$envFile" ]; then
        echo "[$instance] no .env, skipping"
        return 0
    fi

    local current
    current=$(getVar "$envFile" "$VAR")

    if [ "$current" != "$OLD_VERSION" ]; then
        echo "[$instance] $VAR=${current:-<unset>} (not $OLD_VERSION), skipping"
        return 0
    fi

    echo
    echo "[$instance] $VAR: $OLD_VERSION -> $NEW_VERSION"

    setEnv "$VAR" "$NEW_VERSION" "$envFile"

    if [ "$skipRestart" = true ]; then
        echo "[$instance] updated .env (not redeployed)"
        return 0
    fi

    echo "[$instance] redeploying..."
    if ! (cd "$D" && docker compose pull && docker compose up -d); then
        echo "[$instance] redeploy failed, rolling back to $VAR=$OLD_VERSION"
        setEnv "$VAR" "$OLD_VERSION" "$envFile"
        # Restore the previous runtime too, not just the config on disk.
        (cd "$D" && docker compose up -d) || echo "[$instance] WARNING: rollback redeploy failed; manual intervention needed"
        return 1
    fi
    echo "[$instance] redeployed"
}

requireInstance "$INSTANCE"
update_instance "$path"
