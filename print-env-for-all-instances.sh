#!/bin/bash

# Funktion zum Abrufen der Umgebungsvariablen
getVar() {
    local file="$1"
    local var="$2"

    # grep sucht die Zeile mit der Variable, cut extrahiert den Wert
    local value=$(grep "^$var=" "$file" | cut -d '=' -f2-)

    # Falls die Variable nicht existiert oder leer ist, eine Meldung ausgeben
    if [ -z "$value" ]; then
        echo "Variable $var nicht gefunden oder leer"
        return 1
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
          return 1
          ;;
  esac
}

for D in *; do
        if [ -d "${D}" ] && [[ $D == c-* ]]; then
                cd "$D" || exit;
                instance_name="${D#c-}"

                echo "$instance_name -> $(getVar .env COMPOSE_PROFILES) -> $(getComposeProfiles "$(getVar .env COMPOSE_PROFILES)")"
                cd ..
        fi
done
