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
    mv docker-compose.yml docker-compose-old.yml
    cp docker-compose-backend.yml docker-compose.yml
    generate_password
    echo "JWT_SECRET=$password" >> .env
    docker compose up -d
    backend=1
  elif [ "$app" == 0 ]
  then
    source '.env'
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/_users/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    curl -X PUT -u admin:$COUCHDB_PASSWORD https://$APP_URL/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
    echo "'user_app' has access to database 'app'"
  fi
fi
