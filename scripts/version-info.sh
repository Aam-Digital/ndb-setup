#!/bin/bash


##############################
# setup
##############################

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"

# Funktion zum Abrufen der Umgebungsvariablen
getVar() {
    local file="$1"
    local var="$2"
    local value

    # Überprüfen, ob die Datei existiert
    if [ ! -f "$file" ]; then
        echo "n/a"
        return
    fi

    # grep sucht die Zeile mit der Variable, cut extrahiert den Wert
    value=$(grep "^$var=" "$file" | cut -d '=' -f2-)

    # Falls die Variable nicht existiert oder leer ist, eine Meldung ausgeben
    if [ -z "$value" ]; then
      value="n/a"
    fi

    echo "$value"
}

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
echo -e "instance-name \t deployment-type \t app-version \t backend-version \t export-api \t skilllab-api \t notification-api \t change-detection"
echo -e "------------- \t --------------- \t ----------- \t --------------- \t ---------- \t ------------ \t ---------------- \t ----------------"

cd "$baseDirectory" || exit
for D in *; do
        if [ -d "${D}" ] && [[ $D == "$PREFIX"* ]]; then
                cd "$D" || exit;
                instance_name="${D}"

                echo -e -n "$instance_name \t"
                echo -e -n "$(getVar .env COMPOSE_PROFILES) \t"
                echo -e -n "$(getVar .env APP_VERSION) \t"
                echo -e -n "$(getVar .env AAM_BACKEND_SERVICE_VERSION) \t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_EXPORTAPI_ENABLED)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_SKILLAPI_MODE)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env FEATURES_NOTIFICATIONAPI_ENABLED)\t"
                echo -e -n "$(getVar config/aam-backend-service/application.env DATABASECHANGEDETECTION_ENABLED)\t"
                echo "" # new row

                cd ..
        fi
done

} | column -t
