#!/bin/bash
# Migration: switch instances to the renamed aam-services image and to image
# tags without a `v` prefix.
#
# aam-backend-service is now published as ghcr.io/aam-digital/aam-services, and
# both it and replication-backend are tagged `1.22.14` rather than `v1.22.14`.
# The image name (docker-compose.yml) and the version (.env) are changed
# together per instance: either one alone points the instance at a tag that
# does not exist.
#
# A value is only rewritten once the new tag exists on ghcr.io, so an instance
# pinned to a version that was not published under the new form is skipped
# with a warning and keeps running what it runs now. Safe to re-run.
# Does not redeploy: the change takes effect on the next `docker compose up`.
#
# Usage: migrate-image-versions-without-v.sh [instance]
#
# Can be run from any directory.

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

# Whether ghcr.io/aam-digital/<image>:<tag> can be pulled anonymously.
tagExists() {
  local image="$1"
  local tag="$2"
  local token
  token=$(curl -fsL "https://ghcr.io/token?scope=repository:aam-digital/$image:pull" | jq -r .token) || return 1
  curl -fsI -o /dev/null \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/aam-digital/$image/manifests/$tag"
}

migrate_instance() {
  local D="$1"
  local instance="${D##*/}"
  local envFile="$D/.env"
  local composeFile="$D/docker-compose.yml"

  if [ ! -f "$envFile" ] || [ ! -f "$composeFile" ]; then
    echo "[$instance] no .env or docker-compose.yml, skipping"
    return
  fi
  echo "[$instance]"

  # replication-backend: same image, only the tag changes
  local replication
  replication=$(getVar "$envFile" AAM_REPLICATION_BACKEND_VERSION)
  if [[ "$replication" == v* ]]; then
    if tagExists replication-backend "${replication#v}"; then
      backupFile "$envFile"
      setEnv AAM_REPLICATION_BACKEND_VERSION "${replication#v}" "$envFile"
    else
      echo "  WARNING: replication-backend:${replication#v} not found on ghcr.io, keeping $replication"
    fi
  fi

  # aam-backend-service: new image name and new tag, changed together
  if grep -q 'ghcr.io/aam-digital/aam-backend-service:' "$composeFile"; then
    local backend newBackend
    backend=$(getVar "$envFile" AAM_BACKEND_SERVICE_VERSION)
    newBackend="${backend#v}"
    if tagExists aam-services "${newBackend:-latest}"; then
      backupFile "$composeFile"
      sed -i 's|ghcr.io/aam-digital/aam-backend-service:|ghcr.io/aam-digital/aam-services:|' "$composeFile"
      echo "  ~ updated aam-backend-service image in docker-compose.yml"
      if [ "$backend" != "$newBackend" ]; then
        backupFile "$envFile"
        setEnv AAM_BACKEND_SERVICE_VERSION "$newBackend" "$envFile"
      fi
    else
      echo "  WARNING: aam-services:${newBackend:-latest} not found on ghcr.io, keeping aam-backend-service:${backend:-latest}"
    fi
  fi
}

forEachInstance migrate_instance "${1:-}"
