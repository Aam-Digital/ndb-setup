#!/bin/bash


##############################
# setup
##############################

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

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
          ;;
  esac
}

{
echo -e "instance-name \t deployment-type \t app-version \t replication-backend \t backend-version \t export-api \t skilllab-api \t notification-api \t change-detection"
echo -e "------------- \t --------------- \t ----------- \t ------------------- \t --------------- \t ---------- \t ------------ \t ---------------- \t ----------------"

cd "$baseDirectory" || exit
for D in *; do
        if [ -d "${D}" ] && [[ $D == "$PREFIX"* ]]; then
                cd "$D" || exit;
                instance_name="${D}"

                echo -e -n "$instance_name \t"
                echo -e -n "$(getVar .env COMPOSE_PROFILES) \t"
                echo -e -n "$(getVar .env APP_VERSION) \t"
                echo -e -n "$(getVar .env AAM_REPLICATION_BACKEND_VERSION -) \t"
                echo -e -n "$(getVar .env AAM_BACKEND_SERVICE_VERSION -) \t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_EXPORTAPI_ENABLED -)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_SKILLAPI_MODE -)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_NOTIFICATIONAPI_ENABLED -)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env DATABASECHANGEDETECTION_ENABLED -)\t"
                echo "" # new row

                cd ..
        fi
done

} | column -t
