#!/bin/bash

# These might need to be adjusted based on the setup
source "./setup.env"
# Location where Keycloak is running
source "./keycloak/.env"

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for _ in {1..24} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

# Funktion, um den Wert einer Variable aus einer .env-Datei auszulesen
get_env_variable() {
    # Überprüfen, ob die .env-Datei existiert
    if [ -f .env ]; then
        # Die Variable aus der .env-Datei auslesen
        value=$(grep "^$1=" .env | cut -d '=' -f2-)
        # Ausgabe des Werts
        echo "$value"
    else
        echo "Die .env-Datei existiert nicht."
    fi
}

getKeycloakKey() {
  token=$(curl -s -L "https://$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode username=admin --data-urlencode password="$ADMIN_PASSWORD" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli)
  token=${token#*\"access_token\":\"}
  token=${token%%\"*}

  keys=$(curl -s -L "https://$KEYCLOAK_URL/admin/realms/$org/keys" -H "Authorization: Bearer $token")
  kid=${keys#*\"RS256\":\"}
  kid=${kid%%\"*}
  keys=${keys#*\"algorithm\":\"RS256\",}
  publicKey=${keys#*\"publicKey\":\"}
  publicKey=${publicKey%%\"*}

  sed -i "s/\#\- .\/keycloak/\- .\/keycloak/g" "$path/docker-compose.yml"
}

if [ -n "$1" ]; then
  org="$1"
else
  echo "What is the name of the organisation?"
  read -r org
fi
# always ensure org is lowercase to avoid problems with keycloak realms being case sensitive
org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

path="../$PREFIX$org"
app=$(docker ps | grep -ic "\-$org-app")
if [ "$app" == 0 ]; then
  echo "Setting up new instance '$org'"
  mkdir "$path"
  cp .env "$path/.env"
  cp couchdb.ini "$path/couchdb.ini"
  cp config.json "$path/config.json"
  cp docker-compose.yml "$path/docker-compose.yml"

  # fetching latest version from GitHub
  version=$(curl -s -L 'https://github.com/Aam-Digital/ndb-core/releases/latest' -H 'Accept: application/json')
  version=${version#*\"tag_name\":\"}
  version=${version%%\"*}
  echo "VERSION=$version" >> "$path/.env"
  echo "COUCHDB_USER=admin" >> "$path/.env"

  generate_password
  couchdbPassword=$password
  echo "COUCHDB_PASSWORD=$password" >> "$path/.env"
  echo "Admin password: $password"

  generate_password
  echo "JWT_SECRET=$password" >> "$path/.env"

  url=$org.$DOMAIN
  echo "APP_URL=$url" >> "$path/.env"
  echo "App URL: $url"
else
  if [ -n "$1" ]; then
    # When started with args, fail on existing name
    echo "ERROR name already exists"
    exit 1
  else
    echo "Instance '$org' already exists"
  fi
fi

replicationBackend=$(docker ps | grep -c "\-$org-replication-backend")
aamBackendService=$(docker ps | grep -c "\-$org-aam-backend-service")

if [ ! -f "$path/keycloak.json" ]; then
  if [ "$app" == 0 ]; then
    keycloak="y"
  else
    echo "Do you want to add authentication via Keycloak?[y/n]"
    read -r keycloak
  fi
  source "$path/.env"
  if [ "$keycloak" == "y" ] || [ "$keycloak" == "Y" ]; then
    if [ -n "$2" ]; then
      locale="$2"
    else
      echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
      read -r locale
    fi

    container=$(docker ps -aqf "name=keycloak-keycloak")
    # Initialize realm and client
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD"
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create realms -s realm="$org" -s displayName="Aam Digital - $org" -s defaultLocale="$locale" -f /realm_config.json -i
    client=$(docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create clients -r "$org" -s baseUrl="https://$APP_URL" -f /client_config.json -i)

    # Get Keycloak config from API
    getKeycloakKey
    curl -s -L "https://$KEYCLOAK_URL/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" -H "Authorization: Bearer $token" > "$path/keycloak.json"
    sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" "$path/config.json"

    # Set Keycloak public key for bearer auth
    if [ "$replicationBackend" == 1 ]; then
      echo "PUBLIC_KEY=$publicKey" >> "$path/.env"
    else
      sed -i "s/<KID>/$kid/g" "$path/couchdb.ini"
      sed -i "s|<PUBLIC_KEY>|$publicKey|g" "$path/couchdb.ini"
    fi

    # wait for DB to be ready
    (cd "$path" && docker compose up -d)
    while [ "$status" != 200 ]; do
      sleep 4
      echo "Waiting for DB to be ready"
      status=$(curl -s -o /dev/null  "https://$APP_URL/db/_utils/" -I -w "%{http_code}\n")
    done
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users"
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app"
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/report-calculation"
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/notification-webhook"
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments"

    if [ "$app" == 1 ]; then
      echo "Do you want to migrate existing users from CouchDB to Keycloak?[y/n]"
      read -r migrate
      if [ "$migrate" == "y" ] || [ "$migrate" == "Y" ]
      then
        couchUrl="https://$APP_URL/db"
        if [ "$replicationBackend" == 1 ]; then couchUrl="$couchUrl/couchdb"; fi
        node keycloak/migrate_couchdb_users.js "$couchUrl" "$COUCHDB_PASSWORD" "https://$KEYCLOAK_URL" "$ADMIN_PASSWORD" "$org"
      fi
    else
      if [ -n "$3" ]; then
        userEmail="$3"
      else
        echo "Email address of initial user"
        read -r userEmail
      fi
      if [ -n "$4" ]; then
        userName="$4"
      else
        echo "Name of initial user"
        read -r userName
      fi
      if [ -n "$userEmail" ] && [ -n "$userName" ]; then
        curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"username\": \"$userName\",\"enabled\": true,\"email\": \"$userEmail\",\"attributes\": {\"exact_username\": \"$userName\"},\"emailVerified\": false,\"credentials\": [], \"requiredActions\": [\"UPDATE_PASSWORD\", \"VERIFY_EMAIL\"]}" "https://$KEYCLOAK_URL/admin/realms/$org/users"
        userId=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_URL/admin/realms/$org/users?username=$userName&exact=true")
        userId=${userId#*\"id\":\"}
        userId=${userId%%\"*}
        echo "User id $userId"
        roles=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_URL/admin/realms/$org/roles")
        curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$roles" "https://$KEYCLOAK_URL/admin/realms/$org/users/$userId/role-mappings/realm"
        curl -X PUT -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '["VERIFY_EMAIL"]' "https://$KEYCLOAK_URL/admin/realms/$org/users/$userId/execute-actions-email?client_id=app&redirect_uri="
        curl -X PUT -u "admin:$COUCHDB_PASSWORD" -H 'Content-Type: application/json' -d "{\"name\": \"$userName\"}" "https://$APP_URL/db/app/User:$userName"
      fi
    fi

    echo "App is connected with Keycloak"
  elif [ "$app" == 0  ]; then
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users"
    if [ "$replicationBackend" == 0 ]; then
      curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    fi
    echo "'user_app' has access to database 'app'"
  fi
fi

if [ "$app" == 0 ]; then
  if [ -n "$5" ]; then
    baseConfig="$5"
  else
    echo "Which basic config do you want to include?"
    read -r baseConfig
  fi
  if [ -n "$baseConfig" ]; then
    # Needs to be in CouchDB '/_bulk_docs' format: https://docs.couchdb.org/en/stable/api/database/bulk-api.html#updating-documents-in-bulk
    curl -u "admin:$COUCHDB_PASSWORD" -d "@baseConfigs/$baseConfig/entities.json" -H 'Content-Type: application/json' "https://$APP_URL/db/app/_bulk_docs"
    if [ -d "baseConfigs/$baseConfig/attachments" ]; then
      # Uploading attachments - ONLY IMAGES ARE SUPPORTED
      # create folder inside 'attachments' with name of the entity containing images with name of the property
      for dir in baseConfigs/"$baseConfig"/attachments/*
      do
        entity=${dir##*/}
        # Create parent document
        rev=$(curl -X PUT -u "admin:$COUCHDB_PASSWORD" -d "{}" "https://$APP_URL/db/app-attachments/$entity")
        rev="${rev#*\"rev\":\"}"
        rev="${rev%%\"*}"
        for file in "$dir"/*
        do
          prop="${file##*/}"
          ext="${prop##*.}"
          prop="${prop%%.*}"
          # Upload image
          rev=$(curl -X PUT -u "admin:$COUCHDB_PASSWORD" -H "Content-Type: image/$ext" --data-binary "@$file" "https://$APP_URL/db/app-attachments/$entity/$prop?rev=$rev")
          rev="${rev#*\"rev\":\"}"
          rev="${rev%%\"*}"
        done
      done
    fi
    if [ -d "baseConfigs/$baseConfig/assets" ]; then
      for dir in baseConfigs/"$baseConfig"/assets/*
      do
        cp -r "$dir" "$path"
        folder=${dir##*/}
        sed -i "s|assets/config.json|assets/config.json\n      - ./$folder:/usr/share/nginx/html/assets/$folder|g" "$path/docker-compose.yml"
      done
      (cd "$path" && docker compose down && docker compose up -d)
    fi
  fi
fi

if [ "$replicationBackend" == 0 ]; then
  if [ -n "$6" ]; then
    withReplicationBackend="$6"
  else
    echo "Do you want to add the permission backend?[y/n]"
    read -r withReplicationBackend
  fi

  if [ "$withReplicationBackend" == "y" ] || [ "$withReplicationBackend" == "Y" ]; then
    echo "APP_BACKEND_URL=http://replication-backend:5984" >> "$path/.env"
    echo "COMPOSE_PROFILES=replication-backend" >> "$path/.env"

    if [ -f "$path/keycloak.json" ]; then
      # adjust Keycloak config
      getKeycloakKey
      echo "PUBLIC_KEY=$publicKey" >> "$path/.env"
      sed -i "s/$kid/<KID>/g" "$path/couchdb.ini"
      sed -i "s|$publicKey|<PUBLIC_KEY>|g" "$path/couchdb.ini"
      (cd "$path" && docker compose down)
    fi

    (cd "$path" && docker compose up -d)
    replicationBackend=1
    echo "replication-backend added"
  elif [ "$app" == 0 ]; then
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  fi

  if [ "$withReplicationBackend" != "y" ] && [ "$withReplicationBackend" != "Y" ]; then
    echo "APP_BACKEND_URL=http://couchdb:5984" >> "$path/.env"
    echo "COMPOSE_PROFILES=" >> "$path/.env"
  fi
fi

if [ "$aamBackendService" == 0 ]; then
  if [ -n "$7" ]; then
    withAamBackendService="$7"
  else
    echo "Do you want to add aam-backend-services (query-backend)?[y/n]"
    read -r withAamBackendService
  fi

  if [ "$withAamBackendService" == "y" ] || [ "$withAamBackendService" == "Y" ]; then
    if [ "$withReplicationBackend" == "y" ] || [ "$withReplicationBackend" == "Y" ]; then
      sed -i -e 's/COMPOSE_PROFILES=replication-backend/COMPOSE_PROFILES=replication-backend,aam-backend-service/g' "$path/.env"
    else
      sed -i -e 's/COMPOSE_PROFILES=/COMPOSE_PROFILES=aam-backend-service/g' "$path/.env"
    fi

    mkdir "$path/config"
    mkdir "$path/config/aam-backend-service"

    generate_password
    {
      echo "CRYPTO_CONFIGURATION_SECRET=$password";
      echo "SPRING_WEBFLUX_BASE_PATH=/api";
      echo "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI=https://keycloak.aam-digital.com/realms/$org";
      echo "SPRING_RABBITMQ_VIRTUALHOST=/";
      echo "SPRING_RABBITMQ_HOST=rabbitmq";
      echo "SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_ENABLED=true";
      echo "SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_MAXATTEMPTS=5";
      echo "COUCHDBCLIENTCONFIGURATION_BASEPATH=http://couchdb:5984";
      echo "COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME=admin";
      echo "COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD=$couchdbPassword";
      echo "SQSCLIENTCONFIGURATION_BASEPATH=http://sqs:4984";
      echo "SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME=admin";
      echo "SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD=$couchdbPassword";
      echo "DATABASECHANGEDETECTION_ENABLED=true";
      echo "REPORTCALCULATIONPROCESSOR_ENABLED=true";
    } >> "$path/config/aam-backend-service/application.env"

    (cd "$path" && docker compose up -d)
    aamBackendService=1
    echo "aam-backend-service added"
  fi
fi

if [ "$app" == 0 ] && [ "$UPTIMEROBOT_API_KEY" != "" ] && [ "$UPTIMEROBOT_ALERT_ID" != "" ]; then
  if [ -n "$8" ]; then
    createsMonitors="$8"
  else
    echo "Do you want create UptimeRobot monitoring?[y/n]"
    read -r createsMonitors
  fi

  if [ "$createsMonitors" == "y" ] || [ "$createsMonitors" == "Y" ]; then
    curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url&friendly_name=Aam - $org App&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    if [ "$replicationBackend" == 1 ]; then
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/api&friendly_name=Aam - $org Backend&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/couchdb/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    else
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    fi
  fi
fi

if [ "$app" == 0 ]; then
  if [ -n "$9" ]; then
    enableSentry="$9"
  else
    echo "Do you want to enable Sentry logging?[y/n]"
    read -r enableSentry
  fi

  if [ "$enableSentry" == "y" ] || [ "$enableSentry" == "Y" ]; then
    echo "SENTRY_ENABLED=true" >> "$path/.env"
    echo "SENTRY_INSTANCE_NAME=$url" >> "$path/.env"

    # aam-backend-service config file
    {
      echo "SENTRY_AUTH_TOKEN=\"$(get_env_variable "SENTRY_AUTH_TOKEN")\"";
      echo "SENTRY_DSN=$(get_env_variable "SENTRY_DSN_AAM_BACKEND_SERVICE")";
      echo "SENTRY_TRACES_SAMPLE_RATE=1.0";
      echo "SENTRY_LOGGING_ENABLED=true";
      echo "SENTRY_ENVIRONMENT=$environment";
      echo "SENTRY_SERVER_NAME=$url";
      echo "SENTRY_ATTACH_THREADS=true";
      echo "SENTRY_ATTACH_STACKTRACE=true";
      echo "SENTRY_ENABLE_TRACING=true";
    } >> "$path/config/aam-backend-service/application.env"

      if [ -n "$env" ]; then
          environment="$env"
        else
          echo "Wich environment are you on?[development/production]"
          read -r environment
        fi

      if [ "$environment" == "development" ] || [ "$environment" == "production" ]; then
        echo "SENTRY_ENVIRONMENT=$environment" >> "$path/.env"
      fi

      (cd "$path" && docker compose up -d)
  fi
fi

echo "DONE app is now available under https://$APP_URL"
