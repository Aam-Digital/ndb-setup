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

                # backup old .env file
                mv .env .env-old

                # create new .env
                cp ../ndb-setup/.env.template ./.env

                # backup old docker-compose
                mv docker-compose.yml docker-compose.yml-old

                # use new docker-compose.yml
                cp ../ndb-setup/docker-compose.yml ./docker-compose.yml

                # migrate values from .env-old
                compose_profiles=$(getComposeProfiles "$(getVar .env-old COMPOSE_PROFILES)")
                keycloakUrl=https://keycloak.aam-digital.com

                sed -i "s/^INSTANCE_NAME=.*/INSTANCE_NAME=$instance_name/g" ".env"
                sed -i "s/^INSTANCE_DOMAIN=.*/INSTANCE_DOMAIN=$(getVar .env-old APP_URL)/g" ".env"
                sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$compose_profiles/g" ".env"
                sed -i "s/^APP_VERSION=.*/APP_VERSION=$(getVar .env-old VERSION)/g" ".env"
                sed -i "s/^AAM_BACKEND_SERVICE_VERSION=.*/AAM_BACKEND_SERVICE_VERSION=v1.13.0/g" ".env"
                sed -i "s/^COUCHDB_USER=.*/COUCHDB_USER=$(getVar .env-old COUCHDB_USER)/g" ".env"
                sed -i "s/^COUCHDB_PASSWORD=.*/COUCHDB_PASSWORD=$(getVar .env-old COUCHDB_PASSWORD)/g" ".env"
                sed -i "s~^KEYCLOAK_URL=.*~KEYCLOAK_URL=$keycloakUrl~g" ".env"
                sed -i "s~^REPLICATION_BACKEND_PUBLIC_KEY=.*~REPLICATION_BACKEND_PUBLIC_KEY=$(getVar .env-old PUBLIC_KEY)~g" ".env"
                sed -i "s~^REPLICATION_BACKEND_JWT_SECRET=.*~REPLICATION_BACKEND_JWT_SECRET=$(getVar .env-old JWT_SECRET)~g" ".env"
                sed -i "s~^SENTRY_DSN=.*~SENTRY_DSN=$(getVar .env-old SENTRY_DSN)~g" ".env"
                sed -i "s/^SENTRY_ENABLED=.*/SENTRY_ENABLED=true/g" ".env"
                sed -i "s/^SENTRY_ENVIRONMENT=.*/SENTRY_ENVIRONMENT=production/g" ".env"

                cd ..
        fi
done

