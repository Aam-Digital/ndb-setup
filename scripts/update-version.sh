#!/bin/bash
# Change the version in each docker-compose.yml file in all folders starting with prefix
if ! [ $# -eq 2 ]; then
        echo "Usage: $0 service old_version new_version"
        echo "Example: $0 ndb-core 3.5.0 3.6.0"
        echo "for ndb-core, replication-backend, aam-services"
        exit
fi

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

OLD_VERSION=$2
NEW_VERSION=$3
case $1 in
        ndb-core)
                VAR="APP_VERSION"
                ;;
        replication-backend)
                VAR="AAM_REPLICATION_BACKEND_VERSION"
                ;;
        aam-services)
                VAR="AAM_BACKEND_SERVICE_VERSION"
                ;;
        *)
                echo "Invalid service name. Use ndb-core, replication-backend, aam-services."
                exit 1
                ;;
esac

for D in *; do
        if [ -d "${D}" ] && [[ $D == "${PREFIX}*" ]]; then
                cd "$D";
                if [ -f ".env" ]
                then
                  if [ $(grep -c "$VAR=$OLD_VERSION" .env) -eq 0 ]
                  then
                    sed -i "s|$VAR=$OLD_VERSION|$VAR=$NEW_VERSION|" .env
                  else
                    echo "$D/.env: $VAR=$OLD_VERSION not found"
                  fi
                fi
                docker compose pull && docker compose up -d;
                cd ..
        fi
done