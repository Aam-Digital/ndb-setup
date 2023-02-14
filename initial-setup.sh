#!/bin/bash
chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
generate_password() {
  password=""
  for i in {1..16} ; do
    password="$password${chars:RANDOM%${#chars}:1}"
  done
}

org=${PWD##*/ndb-}
app=$(docker compose images| grep -c couchdb)
echo "App $app"
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

    url=$org.aam-digital.net
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
echo "backend $backend"

if [ "$backend" == 0 ]
then
  echo "Do you want to add the permission backend?[y/n]"
  read -r withBackend
  if [ "$withBackend" == "y" ] || [ "$withBackend" == "Y" ]
  then
    echo "Adding backend"
    # mv docker-compose.yml docker-compose-old.yml
    cp docker-compose-backend.yml docker-compose.yml
    generate_password
    echo "JWT_SECRET=$password" >> .env
    docker compose up -d
    backend=1
  fi
fi

if [ ! -f "keycloak.json" ]
then
  echo "Do you want to add authentication via Keycloak?[y/n]"
  read -r keycloak
  container=$(docker ps -aqf "name=keycloak-keycloak")
  # This might need to be adjusted, depending where the keycloak is running
  source "/var/docker/nginx-proxy/keycloak/.env"
  source ".env"
  docker exec -i "$container" /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD"
  docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create realms -s realm="$org" -f /realm_config.json -i
  client=$(docker exec -i "$container" /opt/keycloak/bin/kcadm.sh create clients -r "$org" -s baseUrl="https://$APP_URL" -f /client_config.json -i)
  token=$(curl --silent --location "https://$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode username=admin --data-urlencode password="$ADMIN_PASSWORD" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli)
  token=${token#*\"access_token\":\"}
  token=${token%\",\"expires_in\"*}
  curl --silent --location "https://$KEYCLOAK_URL/admin/realms/dev/clients/$client/installation/providers/keycloak-oidc-keycloak-json" --header "Authorization: Bearer $token" > keycloak.json
  docker compose stop
  sed -i "s/\"account_url\": \".*\"/\"account_url\": \"https:\/\/$ACCOUNTS_URL\"/g" config-keycloak.json
  cp config-keycloak.json config.json
  docker compose up -d
  if [ "$keycloak" == "y" ] || [ "$keycloak" == "Y" ]
  then
    if [ "$backend" == 0 ]
    then
      echo ""
    else
      echo ""
    fi
  elif [ "$app" == 0 ]
  then
    source '.env'
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    echo "'user_app' has access to database 'app'"
  fi
fi
