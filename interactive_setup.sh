#!/bin/bash

# This script will create an aam-digital instance.
# all needed credentials are loaded from the Bitwarden Secrets Manager

source "./setup.env"

# check if BWS_ACCESS_TOKEN is set
if [[ -z "${BWS_ACCESS_TOKEN}" ]]; then
  echo "BWS_ACCESS_TOKEN is not set. Abort."
  exit 1
fi

# set server-base to EU instance
bws config server-base https://vault.bitwarden.eu

# load secrets from Bitwarden Secret Manager
DNS_HETZNER_API_TOKEN=$(bws secret -t "$BWS_ACCESS_TOKEN" get "1be6f4e3-2abf-4d53-8e13-b22600ace76e" | jq -r .value)
DNS_HETZNER_ZONE_ID_APP=$(bws secret -t "$BWS_ACCESS_TOKEN" get "f0507ee8-6a72-4dca-b1f1-b22800844dac" | jq -r .value)
KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)
RENDER_API_CLIENT_ID_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b53d7a1d-220e-4e07-b1f9-b22700711f79" | jq -r .value)
RENDER_API_CLIENT_SECRET_DEV=$(bws secret -t "$BWS_ACCESS_TOKEN" get "83a8e38b-fc22-461f-91a0-b22700712b62" | jq -r .value)
SENTRY_AUTH_TOKEN=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b9a3e1eb-3925-4ed6-93f4-b2270073c82c" | jq -r .value)
SENTRY_DSN_APP=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b1b07d2d-05de-41c6-8ac6-b22700766968" | jq -r .value)
SENTRY_DSN_BACKEND=$(bws secret -t "$BWS_ACCESS_TOKEN" get "a858a580-9643-4330-8667-b2270073d7a6" | jq -r .value)

ACCOUNTS_URL=https://accounts.aam-digital.com

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for _ in {1..24} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

getKeycloakToken() {
  token=$(curl -s -L "https://$KEYCLOAK_HOST/realms/master/protocol/openid-connect/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode username="$KEYCLOAK_USER" --data-urlencode password="$KEYCLOAK_PASSWORD" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli)
  token=${token#*\"access_token\":\"}
  token=${token%%\"*}
}

getKeycloakKey() {
  keys=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/keys" -H "Authorization: Bearer $token")
  kid=${keys#*\"RS256\":\"}
  kid=${kid%%\"*}
  keys=${keys#*\"algorithm\":\"RS256\",}
  publicKey=${keys#*\"publicKey\":\"}
  publicKey=${publicKey%%\"*}
}

#####
# Ask Organisation Name
####

if [ -n "$1" ]; then
  org="$1"
else
  echo "What is the name of the organisation?"
  read -r org
fi
# always ensure org is lowercase to avoid problems with keycloak realms being case sensitive
org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

# todo blacklist


#####
# Set DNS entry
####

curl -X "POST" "https://dns.hetzner.com/api/v1/records" \
     -H 'Content-Type: application/json' \
     -H "Auth-API-Token: $DNS_HETZNER_API_TOKEN" \
     -d "{
  \"value\": \"$DNS_SERVER_NAME.aam-digital.net.\",
  \"type\": \"CNAME\",
  \"name\": \"$org\",
  \"zone_id\": \"$DNS_HETZNER_ZONE_ID_APP\"
}"

#####
# Create folder for instance if not already existing
####

path="../$PREFIX$org"
app=$(docker ps | grep -ic "$org-app")

if [ "$app" == 0 ]; then
  echo "Setting up new instance '$org'"
  mkdir "$path"
  cp .env.template "$path/.env"
  cp couchdb.ini "$path/couchdb.ini"
  cp config.json "$path/config.json"
  cp docker-compose.yml "$path/docker-compose.yml"
  mkdir -p "$path/couchdb/data"

  sed -i "s/^INSTANCE_NAME=.*/INSTANCE_NAME=$org/g" "$path/.env"
  sed -i "s/^INSTANCE_DOMAIN=.*/INSTANCE_DOMAIN=$DOMAIN/g" "$path/.env"

  # fetching latest appVersion from GitHub
  appVersion=$(curl -s -L 'https://github.com/Aam-Digital/ndb-core/releases/latest' -H 'Accept: application/json')
  appVersion=${appVersion#*\"tag_name\":\"}
  appVersion=${appVersion%%\"*}
  sed -i "s/^APP_VERSION=.*/APP_VERSION=$appVersion/g" "$path/.env"

  # setting backend version. Pinned to prevent config conflicts
  backendVersion=v1.10.0
  sed -i "s/^AAM_BACKEND_SERVICE_VERSION=.*/AAM_BACKEND_SERVICE_VERSION=$backendVersion/g" "$path/.env"

  # default couchdb user
  couchDbUser=aam-admin
  sed -i "s/^COUCHDB_USER=.*/COUCHDB_USER=$couchDbUser/g" "$path/.env"

  generate_password
  couchDbPassword=$password

  sed -i "s/^COUCHDB_PASSWORD=.*/COUCHDB_PASSWORD=$password/g" "$path/.env"
  echo "CouchDB admin user: $couchDbUser and password: $couchDbPassword"

  generate_password
  sed -i "s/^REPLICATION_BACKEND_JWT_SECRET=.*/REPLICATION_BACKEND_JWT_SECRET=$password/g" -i "$path/.env"

  url=$org.$DOMAIN

  sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=database-only/g" "$path/.env"

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

#####
# Ask for baseConfig
####

if [ "$app" == 0 ]; then
  if [ -n "$2" ]; then
    baseConfig="$2"
  else
    echo "Which basic config do you want to include? (e.g. [default], basic, codo, ...)"
    read -r baseConfig

    if [ ! "$baseConfig" ]; then
      baseConfig=default
    fi

    if [ ! -d "./baseConfigs/$baseConfig" ]; then
      echo "ERROR Invalid base config '$baseConfig'. Abort."
      exit 1
    fi

  fi
fi

#####
# Keycloak configuration
####
replicationBackend=$(docker ps | grep -c "$org-database") # container only exist, when replication-backend is deployed

sed -i "s/^KEYCLOAK_URL=.*/KEYCLOAK_URL=$KEYCLOAK_HOST/g" "$path/.env"

if [ ! -f "$path/keycloak.json" ]; then
  if [ "$app" == 0 ]; then
    keycloak="y"
  else
    echo "Do you want to add authentication via Keycloak?[y/n]"
    read -r keycloak
  fi

  if [ "$keycloak" == "y" ] || [ "$keycloak" == "Y" ]; then
    if [ -n "$3" ]; then
      locale="$3"
    else
      echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
      read -r locale
    fi

    getKeycloakToken

    # create a realm
    curl -X "POST" "https://$KEYCLOAK_HOST/admin/realms" \
         -H "Authorization: Bearer $token" \
         -H "Content-Type: application/json" \
         -d "$(jq '.realm = "'"$org"'" | .defaultLocale = "'"$locale"'" | .displayName = "Aam Digital - '"$org"'"' ./baseConfigs/"$baseConfig"/realm_config.json)"

    # create a client
    clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$org/clients" \
                          -H "Authorization: Bearer $token" \
                          -H "Content-Type: application/json" \
                          -d "$(jq '.baseUrl = "https://'"$url"'"' ./keycloak/client_config.json)")

    # Extrahiere den Location-Header
    location=$(echo "$clientResponse" | grep -i "^location:")

    # Extrahiere die UUID aus dem Location-Header
    client=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p')

    # Get Keycloak config from API
    getKeycloakKey
    curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" -H "Authorization: Bearer $token" > "$path/keycloak.json"
    sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" "$path/config.json"

    # Set Keycloak public key for bearer auth
    sed -i "s|^REPLICATION_BACKEND_PUBLIC_KEY=.*|REPLICATION_BACKEND_PUBLIC_KEY=$publicKey|g" "$path/.env"
    sed -i "s/<KID>/$kid/g" "$path/couchdb.ini"
    sed -i "s|<PUBLIC_KEY>|$publicKey|g" "$path/couchdb.ini"

    # wait for DB to be ready
    (cd "$path" && docker compose up -d)
    while [ "$status" != 200 ]; do
      sleep 4
      echo "Waiting for DB to be ready"
      status=$(curl -s -o /dev/null  "https://$url/db/_utils/" -I -w "%{http_code}\n")
    done
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/_users"
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/app"
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/report-calculation"
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/notification-webhook"
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/app-attachments"

    if [ "$app" == 1 ]; then
      echo "Do you want to migrate existing users from CouchDB to Keycloak?[y/n]"
      read -r migrate
      if [ "$migrate" == "y" ] || [ "$migrate" == "Y" ]
      then
        couchUrl="https://$url/db"
        if [ "$replicationBackend" == 1 ]; then couchUrl="$couchUrl/couchdb"; fi # todo still needed?
        node keycloak/migrate_couchdb_users.js "$couchUrl" "$couchDbPassword" "https://$KEYCLOAK_HOST" "$ADMIN_PASSWORD" "$org"
      fi
    else
      if [ -n "$4" ]; then
        userEmail="$4"
      else
        echo "Email address of initial user"
        read -r userEmail
      fi
      if [ -n "$5" ]; then
        userName="$5"
      else
        echo "Name of initial user"
        read -r userName
      fi
      if [ -n "$userEmail" ] && [ -n "$userName" ]; then
        curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"username\": \"$userName\",\"enabled\": true,\"email\": \"$userEmail\",\"attributes\": {\"exact_username\": \"$userName\"},\"emailVerified\": false,\"credentials\": [], \"requiredActions\": [\"UPDATE_PASSWORD\", \"VERIFY_EMAIL\"]}" "https://$KEYCLOAK_HOST/admin/realms/$org/users"
        userId=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_HOST/admin/realms/$org/users?username=$userName&exact=true")
        userId=${userId#*\"id\":\"}
        userId=${userId%%\"*}
        echo "User id $userId"
        roles=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_HOST/admin/realms/$org/roles")
        curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$roles" "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/role-mappings/realm"
        curl -X PUT -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '["VERIFY_EMAIL"]' "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/execute-actions-email?client_id=app&redirect_uri="
        curl -X PUT -u "$couchDbUser:$couchDbPassword" -H 'Content-Type: application/json' -d "{\"name\": \"$userName\"}" "https://$url/db/app/User:$userName"
      fi
    fi

    echo "App is connected with Keycloak"
  elif [ "$app" == 0  ]; then
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/_users"
    if [ "$replicationBackend" == 0 ]; then
      curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/_users/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    fi
    echo "'user_app' has access to database 'app'"
  fi
fi

#####
# Apply BaseConfig
####

if [ "$app" == 0 ]; then
  if [ -n "$baseConfig" ]; then
    # Needs to be in CouchDB '/_bulk_docs' format: https://docs.couchdb.org/en/stable/api/database/bulk-api.html#updating-documents-in-bulk
    curl -u "$couchDbUser:$couchDbPassword" -d "@baseConfigs/$baseConfig/entities.json" -H 'Content-Type: application/json' "https://$url/db/app/_bulk_docs"
    if [ -d "baseConfigs/$baseConfig/attachments" ]; then
      # Uploading attachments - ONLY IMAGES ARE SUPPORTED
      # create folder inside 'attachments' with name of the entity containing images with name of the property
      for dir in baseConfigs/"$baseConfig"/attachments/*
      do
        entity=${dir##*/}
        # Create parent document
        rev=$(curl -X PUT -u "$couchDbUser:$couchDbPassword" -d "{}" "https://$url/db/app-attachments/$entity")
        rev="${rev#*\"rev\":\"}"
        rev="${rev%%\"*}"
        for file in "$dir"/*
        do
          prop="${file##*/}"
          ext="${prop##*.}"
          prop="${prop%%.*}"
          # Upload image
          rev=$(curl -X PUT -u "$couchDbUser:$couchDbPassword" -H "Content-Type: image/$ext" --data-binary "@$file" "https://$url/db/app-attachments/$entity/$prop?rev=$rev")
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
    fi
  fi
fi

(cd "$path" && docker compose down && docker stop "$org-database-entrypoint" && docker remove "$org-database-entrypoint")

#####
# Ask for permission backend (replication-backend)
####

if [ "$replicationBackend" == 0 ]; then
  if [ -n "$6" ]; then
    withReplicationBackend="$6"
  else
    echo "Do you want to add the permission backend?[y/n]"
    read -r withReplicationBackend
  fi

  if [ "$withReplicationBackend" == "y" ] || [ "$withReplicationBackend" == "Y" ]; then
    sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=with-permissions/g" "$path/.env"

    if [ -f "$path/keycloak.json" ]; then
      # adjust Keycloak config
      getKeycloakKey
    fi

    replicationBackend=1
    echo "replication-backend added"
  elif [ "$app" == 0 ]; then
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/app/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u "$couchDbUser:$couchDbPassword" "https://$url/db/app-attachments/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  fi
fi

#####
# Ask for aam-backend
####
aamBackendService=$(docker ps | grep -c "$org-aam-backend-service")

if [ "$aamBackendService" == 0 ]; then
  if [ -n "$7" ]; then
    withAamBackendService="$7"
  else
    echo "Do you want to add aam-backend-services (query-backend)?[y/n]"
    read -r withAamBackendService
  fi

  if [ "$withAamBackendService" == "y" ] || [ "$withAamBackendService" == "Y" ]; then
    sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=full-stack/g" "$path/.env"

    mkdir -p "$path/config/aam-backend-service"

    generate_password
    {
      echo "CRYPTO_CONFIGURATION_SECRET=$password";
      echo "SERVER_SERVLET_CONTEXT_PATH=/api";
      echo "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI=https://keycloak.$DOMAIN/realms/$org";
      echo "SPRING_RABBITMQ_VIRTUALHOST=/";
      echo "SPRING_RABBITMQ_HOST=rabbitmq";
      echo "SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_ENABLED=true";
      echo "SPRING_RABBITMQ_LISTENER_DIRECT_RETRY_MAXATTEMPTS=5";
      echo "SPRING_SERVLET_MULTIPART_MAXFILESIZE=5MB";
      echo "LOGGING_LEVEL_COM_AAMDIGITAL_AAMBACKENDSERVICE=warn";
      echo "COUCHDBCLIENTCONFIGURATION_BASEPATH=http://couchdb-with-permissions:5984";
      echo "COUCHDBCLIENTCONFIGURATION_BASICAUTHUSERNAME=$couchDbUser";
      echo "COUCHDBCLIENTCONFIGURATION_BASICAUTHPASSWORD=$couchDbPassword";
      echo "SQSCLIENTCONFIGURATION_BASEPATH=http://sqs:4984";
      echo "SQSCLIENTCONFIGURATION_BASICAUTHUSERNAME=$couchDbUser";
      echo "SQSCLIENTCONFIGURATION_BASICAUTHPASSWORD=$couchDbPassword";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_BASE_PATH=https://pdf.aam-digital.dev";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_ID=$RENDER_API_CLIENT_ID_DEV";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_CLIENT_SECRET=$RENDER_API_CLIENT_SECRET_DEV";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_TOKEN_ENDPOINT=https://auth.aam-digital.dev/realms/aam-digital/protocol/openid-connect/token";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_GRANT_TYPE=client_credentials";
      echo "AAM_RENDER_API_CLIENT_CONFIGURATION_AUTH_CONFIG_SCOPE=";
      echo "DATABASECHANGEDETECTION_ENABLED=true";
      echo "EVENTS_LISTENER_REPORT_CALCULATION_ENABLED=true";
    } >> "$path/config/aam-backend-service/application.env"

    aamBackendService=1
    echo "aam-backend-service added"
  fi
fi

#####
# Ask for uptime monitoring
####

if [ "$app" == 0 ] && [ "$UPTIMEROBOT_API_KEY" != "" ] && [ "$UPTIMEROBOT_ALERT_ID" != "" ]; then
  if [ -n "$8" ]; then
    createsMonitors="$8"
  else
    echo "Do you want create UptimeRobot monitoring? (deprecated, answer is ignored) [y/n]"
    read -r createsMonitors
  fi

#  if [ "$createsMonitors" == "y" ] || [ "$createsMonitors" == "Y" ]; then
#    curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url&friendly_name=Aam - $org App&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
#    if [ "$replicationBackend" == 1 ]; then
#      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/api&friendly_name=Aam - $org Backend&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
#      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/couchdb/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
#    else
#      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
#    fi
#  fi
fi

#####
# Ask for sentry connection
####

if [ "$app" == 0 ]; then
  if [ -n "$9" ]; then
    enableSentry="$9"
  else
    echo "Do you want to enable Sentry logging?[y/n]"
    read -r enableSentry
  fi

  if [ "$enableSentry" == "y" ] || [ "$enableSentry" == "Y" ]; then
    sed -i "s/^SENTRY_ENABLED=.*/SENTRY_ENABLED=true/g" "$path/.env"
    sed -i "s/^SENTRY_DSN=.*/SENTRY_DSN=$SENTRY_DSN_APP/g" "$path/.env"

    mkdir -p "$path/config/aam-backend-service"

    # aam-backend-service config file
    {
      echo "SENTRY_AUTH_TOKEN=$SENTRY_AUTH_TOKEN";
      echo "SENTRY_DSN=$SENTRY_DSN_BACKEND";
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
          echo "Which environment are you on? [development/production]"
          read -r environment
        fi

      if [ "$environment" == "development" ] || [ "$environment" == "production" ]; then
        sed -i "s/^SENTRY_ENVIRONMENT=.*/SENTRY_ENVIRONMENT=$environment/g" "$path/.env"
      fi
  fi
fi

(cd "$path" && docker compose up -d)

echo "DONE app is now available under https://$url"
