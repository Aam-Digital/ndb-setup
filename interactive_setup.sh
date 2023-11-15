#!/bin/bash

# These might need to be adjusted based on the setup
source "./setup.env"
# Location where Keycloak is running
source "./keycloak/.env"

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for _ in {1..16} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
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

path="../$PREFIX$org"
app=$(docker ps | grep -c "\-$org-app")
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

  generate_password
  echo "COUCHDB_PASSWORD=$password" >> "$path/.env"
  echo "Admin password: $password"

  generate_password
  echo "JWT_SECRET=$password" >> "$path/.env"

  url=$org.$DOMAIN
  echo "APP_URL=$url" >> "$path/.env"
  echo "App URL: $url"
else
  echo "Instance '$org' already exists"
fi

backend=$(docker ps | grep -c "\-$org-backend")

if [ ! -f "$path/keycloak.json" ]; then
  if [ "$app" == 0 ]; then
    keycloak="y"
  else
    echo "Do you want to add authentication via Keycloak?[y/n]"
    read -r keycloak
  fi
  source "$path/.env"
  if [ "$keycloak" == "y" ] || [ "$keycloak" == "Y" ]; then
    container=$(docker ps -aqf "name=keycloak-keycloak")
    # Initialize realm and client
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD"
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create realms -s realm="$org" -f /realm_config.json -i
    client=$(docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create clients -r "$org" -s baseUrl="https://$APP_URL" -f /client_config.json -i)

    # Get Keycloak config from API
    getKeycloakKey
    curl -s -L "https://$KEYCLOAK_URL/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" -H "Authorization: Bearer $token" > "$path/keycloak.json"
    sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" "$path/config.json"

    # Set Keycloak public key for bearer auth
    if [ "$backend" == 1 ]; then
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
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments"

    if [ "$app" == 1 ]; then
      echo "Do you want to migrate existing users from CouchDB to Keycloak?[y/n]"
      read -r migrate
      if [ "$migrate" == "y" ] || [ "$migrate" == "Y" ]
      then
        couchUrl="https://$APP_URL/db"
        if [ "$backend" == 1 ]; then couchUrl="$couchUrl/couchdb"; fi
        node keycloak/migrate_couchdb_users.js "$couchUrl" "$COUCHDB_PASSWORD" "https://$KEYCLOAK_URL" "$ADMIN_PASSWORD" "$org"
      fi
    else
      if [ -n "$2" ]; then
        userEmail="$2"
      else
        echo "Email address of initial user"
        read -r userEmail
      fi
      if [ -n "$3" ]; then
        userName="$3"
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
    if [ "$backend" == 0 ]; then
      curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    fi
    echo "'user_app' has access to database 'app'"
  fi
fi

if [ "$backend" == 0 ]; then
  if [ -n "$4" ]; then
    withBackend="$4"
  else
    echo "Do you want to add the permission backend?[y/n]"
    read -r withBackend
  fi

  if [ "$withBackend" == "y" ] || [ "$withBackend" == "Y" ]; then
    echo "COMPOSE_PROFILES=backend" >> "$path/.env"

    if [ -f "$path/keycloak.json" ]; then
      # adjust Keycloak config
      getKeycloakKey
      echo "PUBLIC_KEY=$publicKey" >> "$path/.env"
      sed -i "s/$kid/<KID>/g" "$path/couchdb.ini"
      sed -i "s|$publicKey|<PUBLIC_KEY>|g" "$path/couchdb.ini"
      (cd "$path" && docker compose down)
    fi

    (cd "$path" && docker compose up -d)
    backend=1
    echo "Backend added"
  elif [ "$app" == 0 ]; then
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  fi
fi



if [ "$app" == 0 ] && [ "$UPTIMEROBOT_API_KEY" != "" ] && [ "$UPTIMEROBOT_ALERT_ID" != "" ]; then
  if [ -n "$5" ]; then
    createsMonitors="$5"
  else
    echo "Do you want create UptimeRobot monitoring?[y/n]"
    read -r createsMonitors
  fi

  if [ "$createsMonitors" == "y" ] || [ "$createsMonitors" == "Y" ]; then
    curl -X POST -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url&friendly_name=Aam - $org App&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    if [ "$backend" == 1 ]; then
      curl -X POST -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/api&friendly_name=Aam - $org Backend&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
      curl -X POST -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/couchdb/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    else
      curl -X POST -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    fi
  fi
fi

echo "app is now available under https://$APP_URL"
