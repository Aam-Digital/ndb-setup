#!/bin/bash

chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for i in {1..16} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

org=${PWD##*/ndb-}
app=$(docker compose images 2>/dev/null | grep -c couchdb)
if [ "$app" == 0 ]
then
  echo "Setting up new instance '$org'"

  if [ ! -f ".env" ]
  then
    # TODO maybe fetch latest from server
    echo "Which version should be used (e.g. 3.18.0 or pr-1234)?"
    read -r version
    echo "VERSION=$version" >> .env

    generate_password
    echo "COUCHDB_PASSWORD=$password" >> .env
    echo "Admin password: $password"

    # This needs to be set manually after running the script
    echo "SENTRY_DSN=" >> .env

    # might need to be adjusted base on the domain
    url=$org.aam-digital.com
    echo "APP_URL=$url" >> .env
    echo "App URL: $url"
  fi
  docker compose up -d

  # wait for DB to be ready
  source '.env'
  while [ "$status" != 200 ]
  do
    sleep 1
    echo "Waiting for DB to be ready"
    status=$(curl --silent --output /dev/null  https://$APP_URL/db/_utils/ -I -w "%{http_code}\n")
  done
  curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/app

else
  echo "Instance '$org' already exists"
fi

backend=$(docker compose images | grep -c backend)
if [ "$backend" == 0 ]
then
  echo "Do you want to add the permission backend?[y/n]"
  read -r withBackend
  if [ "$withBackend" == "y" ] || [ "$withBackend" == "Y" ]
  then
    mv docker-compose.yml docker-compose-old.yml
    cp docker-compose-backend.yml docker-compose.yml
    generate_password
    echo "JWT_SECRET=$password" >> .env
    docker compose up -d
    backend=1
    echo "Backend added"
 fi
fi

if [ ! -f "keycloak.json" ]
then
  echo "Do you want to add authentication via Keycloak?[y/n]"
  read -r keycloak
  source '.env'
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
    curl --silent --location "https://$KEYCLOAK_URL/admin/realms/dev/clients/$client/installation/providers/keycloak-oidc-keycloak-json" --header "Authorization: Bearer $token" > keycloak.json
    sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" config-keycloak.json
    cp config-keycloak.json config.json
    sed -i "s/\#\- .\/keycloak/\- .\/keycloak/g" docker-compose.yml

    # Set Keycloak public key vor bearer auth
    keys=$(curl --silent --location "https://$KEYCLOAK_URL/admin/realms/master/keys" --header "Authorization: Bearer $token")
    kid=${keys#*\"RS256\":\"}
    kid=${kid%%\"*}
    keys=${keys#*\"algorithm\":\"RS256\",}
    publicKey=${keys#*\"publicKey\":\"}
    publicKey=${publicKey%%\"*}
    if [ "$backend" == 0 ]
    then
      sed -i "s/<KID>/$kid/g" couchdb.ini
      sed -i "s|<PUBLIC_KEY>|$publicKey|g" couchdb.ini
    else
      echo "PUBLIC_KEY=$publicKey" >> .env
    fi
    docker compose stop
    docker compose up -d

    echo "Do you want to migrate existing users from CouchDB to Keycloak?[y/n]"
    read -r migrate
    source '.env'
    if [ "$migrate" == "y" ] || [ "$migrate" == "Y" ]
    then
      couchUrl=https://$APP_URL/db
      if [ "$backend" == 1 ]; then couchUrl=$couchUrl/couchdb; fi
      node keycloak/migrate_couchdb_users.js $couchUrl $COUCHDB_PASSWORD https://$KEYCLOAK_URL $ADMIN_PASSWORD $org
    fi

    echo "App is connected with Keycloak"
  elif [ "$app" == 0 ]
  then
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    echo "'user_app' has access to database 'app'"
  fi
fi
