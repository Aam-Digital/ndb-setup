#!/bin/bash

# This script will create an aam-digital instance.
# all needed credentials are loaded from the Bitwarden Secrets Manager

# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./interactive-setup.sh <instance> <baseConfig> <locale> <userEmail> <userName> <withReplicationBackend> <withBackend> <createsMonitors> <enableSentry>
# example: ./interactive-setup.sh qm codo de "mail@foo.bar" "Foo Bar" y y y y
#
# Attention: on macos, see setEnv function and enable the macos line instead the linux line
#


##############################
# setup
##############################

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

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
SENTRY_DSN_APP=$(bws secret -t "$BWS_ACCESS_TOKEN" get "b1b07d2d-05de-41c6-8ac6-b22700766968" | jq -r .value)
SENTRY_DSN_REPLICATION_BACKEND=$(bws secret -t "$BWS_ACCESS_TOKEN" get "359ea1c0-798e-4e17-ae44-b2e20153051d" | jq -r .value)
SMTP_SERVER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "55bf05ce-03ed-40fb-8320-b2ce00cf6760" | jq -r .value)
SMTP_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "ec5d7f0a-62e3-46d7-a7c7-b2ce00cf8abc" | jq -r .value)

##############################
# functions
##############################

getKeycloakKey() {
  keys=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/keys" -H "Authorization: Bearer $token")
  kid=${keys#*\"RS256\":\"}
  kid=${kid%%\"*}
  keys=${keys#*\"algorithm\":\"RS256\",}
  publicKey=${keys#*\"publicKey\":\"}
  publicKey=${publicKey%%\"*}
}

# Function to check if the first filename exists, if not, return the second filename
fileOrDefault() {
  local primary_file="$1"
  local default_file="$2"

  if [[ -f "$primary_file" ]]; then
    echo "$primary_file"
  else
    echo "$default_file"
  fi
}

##############################
# script
##############################

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

if grep -Fxq "$org" "$baseDirectory/ndb-setup/scripts/blacklist.txt"; then
    echo "Error: The organisation name '$org' is blacklisted. Please try another one."
    exit 1
fi

echo "organisation name length: ${#org}"

if [ ${#org} -ge 24 ]; then
    echo "Error: The organisation name must have less than 24 letters. Please try a shorter one."
    exit 1
fi

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

path="$baseDirectory/$PREFIX$org"
app=$(docker ps | grep -ic "$org-app")

if [ "$app" == 0 ]; then
  echo "Setting up new instance '$org'"
  mkdir "$path"
  cp $baseDirectory/ndb-setup/.env.template "$path/.env"
  cp $baseDirectory/ndb-setup/couchdb.ini "$path/couchdb.ini"
  jq --arg email "${WEBMASTER_EMAIL:-webmaster@example.com}" '.webmaster_email = $email' \
    "$baseDirectory/ndb-setup/config.json" > "$path/config.json"
  cp $baseDirectory/ndb-setup/docker-compose.yml "$path/docker-compose.yml"
  cp $baseDirectory/ndb-setup/firebase-config.json "$path/firebase-config.json"
  mkdir -p "$path/couchdb/data"

  setEnv INSTANCE_NAME "$org" "$path/.env"
  setEnv INSTANCE_DOMAIN "$DOMAIN" "$path/.env"

  # setting frontend app version. Using latest available version
  appVersion=$(curl -s https://api.github.com/repos/Aam-Digital/ndb-core/releases | jq -r 'map(select(.name | test("-") | not)) | .[0].name')
  setEnv APP_VERSION "$appVersion" "$path/.env"

  # setting replication-backend version. Using latest available version
  replicationBackendVersion=$(curl -s https://api.github.com/repos/Aam-Digital/replication-backend/releases | jq -r 'map(select(.name | test("-") | not)) | .[0].name')
  setEnv AAM_REPLICATION_BACKEND_VERSION "$replicationBackendVersion" "$path/.env"

  # setting backend version. Using latest available version
  backendVersion=$(getLatestBackendVersion)
  setEnv AAM_BACKEND_SERVICE_VERSION "$backendVersion" "$path/.env"

  # default couchdb user
  couchDbUser=aam-admin
  setEnv COUCHDB_USER "$couchDbUser" "$path/.env"

  couchDbPassword=$(generate_password)

  setEnv COUCHDB_PASSWORD "$couchDbPassword" "$path/.env"
  echo "CouchDB admin user: $couchDbUser and password: $couchDbPassword"

  setEnv REPLICATION_BACKEND_JWT_SECRET "$(generate_password)" "$path/.env"

  url=$org.$DOMAIN

  setEnv COMPOSE_PROFILES "database-only" "$path/.env"

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

    if [ ! -d "$baseDirectory/ndb-setup/baseConfigs/$baseConfig" ]; then
      echo "ERROR Invalid base config '$baseConfig'. Abort."
      exit 1
    fi

  fi
fi

#####
# Keycloak configuration
####
replicationBackend=$(docker ps | grep -c "$org-database") # container only exist, when replication-backend is deployed

setEnv KEYCLOAK_URL "$KEYCLOAK_HOST" "$path/.env"

if [ ! -f "$path/keycloak.json" ]; then

  if [ -n "$3" ]; then
    locale="$3"
  else
    echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
    read -r locale
  fi

  getKeycloakToken

  # take the custom baseConfig realm file or otherwise the default from keycloak folder
  keycloakRealmFile=$(fileOrDefault "$baseDirectory/ndb-setup/baseConfigs/$baseConfig/realm_config.json" "$baseDirectory/ndb-setup/keycloak/realm_config.json")
  # add and replace some customized values
  keycloakRealmJson=$(jq '
    .realm = "'"$org"'" |
    .defaultLocale = "'"$locale"'" |
    .displayName = "Aam Digital - '"$org"'" |
    .smtpServer.from = "accounts@aam-digital.com" |
    .smtpServer.host = "'"$SMTP_SERVER"'" |
    .smtpServer.port = "587" |
    .smtpServer.user = "accounts@aam-digital.com" |
    .smtpServer.password = "'"$SMTP_PASSWORD"'"
    ' "$keycloakRealmFile")

  # create a realm
  curl -X "POST" "https://$KEYCLOAK_HOST/admin/realms" \
       -H "Authorization: Bearer $token" \
       -H "Content-Type: application/json" \
       -d "$keycloakRealmJson"

  # create a client
  clientResponse=$(curl -s -D - -o /dev/null -X POST "https://$KEYCLOAK_HOST/admin/realms/$org/clients" \
                        -H "Authorization: Bearer $token" \
                        -H "Content-Type: application/json" \
                        -d "$(jq '.baseUrl = "https://'"$url"'"' $baseDirectory/ndb-setup/keycloak/client_config.json)")

  # Extrahiere den Location-Header
  location=$(echo "$clientResponse" | grep -i "^location:")

  # Extrahiere die UUID aus dem Location-Header
  client=$(echo "$location" | sed -n 's#.*\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\).*#\1#p') # todo mac/linux

  # Get Keycloak config from API
  getKeycloakKey
  curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" -H "Authorization: Bearer $token" > "$path/keycloak.json"

  # Set Keycloak public key for bearer auth
  echo "set publicKey in .env"
  sed -i "s|^REPLICATION_BACKEND_PUBLIC_KEY=.*|REPLICATION_BACKEND_PUBLIC_KEY=$publicKey|g" "$path/.env" # todo mac/linux

  echo "set kid in .couchdb.ini"
  sed -i "s/<KID>/$kid/g" "$path/couchdb.ini" # todo mac/linux

  echo "set publicKey in couchdb.ini"
  sed -i "s|<PUBLIC_KEY>|$publicKey|g" "$path/couchdb.ini" # todo mac/linux

  # wait for DB to be ready
  (cd "$path" && docker compose up -d)
  dbContainer="${org}-db-entrypoint"
  dbLocalUrl="http://127.0.0.1:5984"
  while [ "$status" != "200" ]; do
    sleep 4
    echo "Waiting for DB to be ready"
    status=$(docker exec "$dbContainer" curl -s -o /dev/null -w "%{http_code}" -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/_up")
  done
  docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/_users"
  docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/app"
  docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/report-calculation"
  docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/notification-webhook"
  docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/app-attachments"

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
    curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"username\": \"$userName\",\"enabled\": true,\"email\": \"$userEmail\",\"attributes\": {\"exact_username\": \"User:$userName\"},\"emailVerified\": false,\"credentials\": [], \"requiredActions\": [\"UPDATE_PASSWORD\", \"VERIFY_EMAIL\"]}" "https://$KEYCLOAK_HOST/admin/realms/$org/users"
    userId=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_HOST/admin/realms/$org/users?username=$userName&exact=true")
    userId=${userId#*\"id\":\"}
    userId=${userId%%\"*}
    echo "User id $userId"
    roles=$(curl -s -H "Authorization: Bearer $token" "https://$KEYCLOAK_HOST/admin/realms/$org/roles")
    echo "create roles..."
    curl -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$roles" "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/role-mappings/realm"
    echo "verify email..."
    # no redirect_uri: Keycloak falls back to the "app" client's baseUrl (set above) for the "back to application" link
    curl -X PUT -s -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '["VERIFY_EMAIL"]' "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/execute-actions-email?client_id=app"

    echo "enable 2fa for user..."
    roleId=$(curl -X GET "https://$KEYCLOAK_HOST/admin/realms/$org/roles" -H "Authorization: Bearer $token" | jq -r '.[] | select(.name=="no-email-2fa") | .id')
    echo "$roleId"
    if [ -z "$roleId" ]; then
      echo "Fehler: Keine Rolle 'no-email-2fa' gefunden."
    else
      curl -X DELETE "https://$KEYCLOAK_HOST/admin/realms/$org/users/$userId/role-mappings/realm" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "[{\"id\": \"$roleId\"}]"
    fi

    echo "create user document in couchdb..."
    docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" -H 'Content-Type: application/json' -d "{\"name\": \"$userName\"}" "$dbLocalUrl/app/User:$userName"
  fi

  echo "App is connected with Keycloak"
fi

#####
# Apply BaseConfig
####

if [ "$app" == 0 ]; then
  if [ -n "$baseConfig" ]; then
    # to add config or other docs to CouchDB, mount them to the assets/base-configs folder of ndb-core
    # and use an `available-configs.json` entry to make it selectable in the app
    # see https://github.com/Aam-Digital/ndb-core/blob/master/src/assets/base-configs/available-configs.json

    if [ -d "$baseDirectory/ndb-setup/baseConfigs/$baseConfig/assets" ]; then
      $baseDirectory/ndb-setup/scripts/enable-assets-overwrites.sh "$org" "$baseConfig"
    fi

    # Apply a config overlay shipped by the baseConfig. The baseConfig's `config/` folder mirrors the
    # instance `config/` tree 1:1 and is copied verbatim, so e.g. a custom notification email template at
    # `config/aam-backend-service/templates/notification/create-notification-email-template.html` lands at
    # the path docker-compose mounts into the aam-backend-service container (/opt/app/templates).
    # Note: this only adds files (e.g. templates/); the per-instance application.env is generated later by
    # enable-backend.sh, so the two never collide.
    if [ -d "$baseDirectory/ndb-setup/baseConfigs/$baseConfig/config" ]; then
      echo "Applying config overlay from baseConfig '$baseConfig'..."
      mkdir -p "$path/config"
      cp -r "$baseDirectory/ndb-setup/baseConfigs/$baseConfig/config/." "$path/config/"
    fi
  fi
fi

(cd "$path" && docker compose down && docker stop "$org-db-entrypoint" && docker remove "$org-db-entrypoint")
echo "The error response above ('No such container...') can be ignored."

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
  setEnv COMPOSE_PROFILES "with-permissions" "$path/.env"

    if [ -f "$path/keycloak.json" ]; then
      # adjust Keycloak config
      getKeycloakKey
    fi

    replicationBackend=1
    echo "replication-backend added"
  elif [ "$app" == 0 ]; then

    # wait for DB to be ready
    (cd "$path" && docker compose up -d)
    dbContainer="${org}-db-entrypoint"
    dbLocalUrl="http://127.0.0.1:5984"

    while [ "$status" != "200" ]; do
      sleep 4
      echo "Waiting for DB to be ready"
      status=$(docker exec "$dbContainer" curl -s -o /dev/null -w "%{http_code}" -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/_up")
    done

    docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/app/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    docker exec "$dbContainer" curl -s -X PUT -u "$couchDbUser:$couchDbPassword" "$dbLocalUrl/app-attachments/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'

    (cd "$path" && docker compose down && docker stop "$org-db-entrypoint" && docker remove "$org-db-entrypoint")
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
    $baseDirectory/ndb-setup/scripts/enable-backend.sh "$org" --skip-restart
    aamBackendService=1

    # Enabling the backend also enables (push + email) notifications by default. The enable script loads the
    # Firebase credentials from BWS, so this runs non-interactively. --skip-restart is passed because this
    # script restarts the stack once at the very end, after all enable-* scripts have written their config.
    $baseDirectory/ndb-setup/scripts/enable-feature-notification.sh "$org" --skip-restart
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
    setEnv SENTRY_DSN "$SENTRY_DSN_APP" "$path/.env"
    setEnv SENTRY_DSN_REPLICATION_BACKEND "$SENTRY_DSN_REPLICATION_BACKEND" "$path/.env"
    setEnv SENTRY_ENABLED "true" "$path/.env"
    setEnv SENTRY_ENVIRONMENT "production" "$path/.env"
  else
    setEnv SENTRY_LOGGING_ENABLED "false" "$path/config/aam-backend-service/application.env"
  fi
fi

# Single restart for the whole instance, after every enable-* script (run with --skip-restart) has written
# its config. `down && up -d` (not just `up -d`) forces recreation so changed env_file/config is picked up.
(cd "$path" && docker compose down && docker compose up -d)

echo "DONE app is now available under https://$url"
