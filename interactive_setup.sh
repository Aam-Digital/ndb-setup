#!/bin/bash

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for _ in {1..16} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

echo "What is the name of the organisation?"
read -r org
path="../ndb-$org"
[[ -d "$path" ]] && app=1
if [ "$app" != 1 ]
then
  echo "Setting up new instance '$org'"
  mkdir "$path"
  cp .env "$path/.env"
  cp couchdb.ini "$path/couchdb.ini"
  cp config.json "$path/config.json"
  cp docker-compose.yml "$path/docker-compose.yml"

  # TODO maybe fetch latest from server
  echo "Which version should be used (e.g. 3.18.0 or pr-1234)?"
  read -r version
  echo "VERSION=$version" >> "$path/.env"

  generate_password
  echo "COUCHDB_PASSWORD=$password" >> "$path/.env"
  echo "Admin password: $password"

  # might need to be adjusted base on the domain
  url=$org.aam-digital.net
  echo "APP_URL=$url" >> "$path/.env"
  echo "App URL: $url"
  (cd "$path" && docker compose up -d)

  # wait for DB to be ready
  source "$path/.env"
  while [ "$status" != 200 ]
  do
    sleep 4
    echo "Waiting for DB to be ready"
    status=$(curl --silent --output /dev/null  "https://$APP_URL/db/_utils/" -I -w "%{http_code}\n")
  done
  curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app"
  curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments"
else
  echo "Instance '$org' already exists"
fi

backend=$(docker ps | grep -c "\-$org-backend")
if [ "$backend" == 0 ]
then
  echo "Do you want to add the permission backend?[y/n]"
  read -r withBackend
  if [ "$withBackend" == "y" ] || [ "$withBackend" == "Y" ]
  then
    cp docker-compose-backend.yml "$path/docker-compose.yml"
    generate_password
    echo "JWT_SECRET=$password" >> "$path/.env"
    (cd "$path" && docker compose up -d)
    backend=1
    echo "Backend added"
 elif [ "$app" != 1 ]; then
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/app-attachments/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  fi
fi

if [ ! -f "keycloak.json" ]
then
  echo "Do you want to add authentication via Keycloak?[y/n]"
  read -r keycloak
  source "$path/.env"
  if [ "$keycloak" == "y" ] || [ "$keycloak" == "Y" ]
  then
    container=$(docker ps -aqf "name=keycloak-keycloak")
    # This might need to be adjusted, depending where the keycloak is running
    source "/var/docker/nginx-proxy/keycloak/.env"
    # Initialize realm and client
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD"
    docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create realms -s realm="$org" -f /realm_config.json -i
    client=$(docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create clients -r "$org" -s baseUrl="https://$APP_URL" -f /client_config.json -i)

    # Get Keycloak config from API
    token=$(curl --silent --location "https://$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode username=admin --data-urlencode password="$ADMIN_PASSWORD" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli)
    token=${token#*\"access_token\":\"}
    token=${token%%\"*}
    curl --silent --location "https://$KEYCLOAK_URL/admin/realms/$org/clients/$client/installation/providers/keycloak-oidc-keycloak-json" --header "Authorization: Bearer $token" > "$path/keycloak.json"
    cp config-keycloak.json "$path/config.json"
    sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" "$path/config.json"
    sed -i "s/\#\- .\/keycloak/\- .\/keycloak/g" "$path/docker-compose.yml"

    # Set Keycloak public key vor bearer auth
    keys=$(curl --silent --location "https://$KEYCLOAK_URL/admin/realms/$org/keys" --header "Authorization: Bearer $token")
    kid=${keys#*\"RS256\":\"}
    kid=${kid%%\"*}
    keys=${keys#*\"algorithm\":\"RS256\",}
    publicKey=${keys#*\"publicKey\":\"}
    publicKey=${publicKey%%\"*}
    if [ "$backend" != 1 ]
    then
      sed -i "s/<KID>/$kid/g" "$path/couchdb.ini"
      sed -i "s|<PUBLIC_KEY>|$publicKey|g" "$path/couchdb.ini"
    else
      echo "PUBLIC_KEY=$publicKey" >> "$path/.env"
    fi
    (cd "$path" && docker compose stop && docker compose up -d)

    if [ "$app" == 1 ]; then
      echo "Do you want to migrate existing users from CouchDB to Keycloak?[y/n]"
      read -r migrate
      if [ "$migrate" == "y" ] || [ "$migrate" == "Y" ]
      then
        couchUrl="https://$APP_URL/db"
        if [ "$backend" == 1 ]; then couchUrl="$couchUrl/couchdb"; fi
        node keycloak/migrate_couchdb_users.js "$couchUrl" "$COUCHDB_PASSWORD" "https://$KEYCLOAK_URL" "$ADMIN_PASSWORD" "$org"
      fi
    fi

    echo "App is connected with Keycloak"
  elif [ "$app" != 1  ]
  then
    curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users"
    if [ "$backend" != 1 ]; then
      curl -X PUT -u "admin:$COUCHDB_PASSWORD" "https://$APP_URL/db/_users/_security" -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    fi

    echo "'user_app' has access to database 'app'"
  fi
fi
