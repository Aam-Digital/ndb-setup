# Aam Digital Setup
This repository describes how to setup everything that is needed to run Aam Digital in production.
This includes deploying the app, deploying and connecting the database and optionally deploying and connecting the permission backend.

## Deploying with permission backend
Use this deployment if you want to enable permission checks in your application

1. Clone this repository `git clone https://github.com/Aam-Digital/ndb-setup.git`
2. Edit the `docker-compose.yml`
   1. in `app` set `VIRTUAL_HOST` and `LETSENCRYPT_HOST` to the desired URL. Set `depends_on` to `backend` and replace `COUCHDB_URL: http://couchdb:5984` with `COUCHDB_URL: http://backend:3000` (change commented out parts)
   2. Remove comments of `backend` section and set `DATABASE_PASSWORD` to a secure password. This is used for the replication process. (optional) set `SENTRY_DSN` to your [Sentry DSN](https://docs.sentry.io/product/sentry-basics/dsn-explainer/) to enable error logging. 
   3. in `couchdb` set `COUCHDB_PASSWORD` to **another** secure password. This is used for admin tasks on the database. 
3. Create a `config.json` file by copying the [default config](https://github.com/Aam-Digital/ndb-core/blob/master/src/assets/config.default.json)
4. Run `docker-compose up -d`
5. Run `./initial-setup.sh https://<VIRTUAL_HOST> <COUCHDB_PASSWORD> <DATABASE_PASSWORD>`
6. To add users run `js add-user.js <VIRTUAL_HOST> admin:<COUCHDB_PASSWORD> <USERNAME> <PASSWORD>` where `USERNAME` and `PASSWORD` are the desired user credentials.
7. Visit `<VIRTUAL_HOST>/db/db/_utils/` and add a `Config:Permission` document (TODO add link once documentation is deployed) to the database and define the user roles
8. Visit `<VIRTUAL_HOST>/db/api/` and execute the `POST /_session` and `POST /rules/{db}/reload` to activate the changes in the backend

## Deploying without permission backend
To set up the application with a direct connection to the database, without a permission backend, follow these steps:

1. Clone this repository to easily get all the setup files: `git clone https://github.com/Aam-Digital/ndb-setup.git`
2. Edit the `docker-compose.yml`
   1. in `app` set `VIRTUAL_HOST` and `LETSENCRYPT_HOST` to the desired URL.
   2. in `couchdb` set `COUCHDB_PASSWORD` to secure password. This is used for admin tasks on the database.
3. Create a `config.json` file by copying the [default config](https://github.com/Aam-Digital/ndb-core/blob/master/src/assets/config.default.json)
4. Run `docker-compose up -d`
5. Run `./initial-setup.sh https://<VIRTUAL_HOST> <COUCHDB_PASSWORD>`
6. To add users run `js add-user.js <VIRTUAL_HOST> admin:<COUCHDB_PASSWORD> <USERNAME> <PASSWORD>` where `USERNAME` and `PASSWORD` are the desired user credentials.

# Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/jwilder/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

see our [nginxproxy.docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/nginxproxy.docker-compose.yaml) for a sample service that can be copied. Then simply adapt the VIRTUAL_HOST environment variable of the ndb-server docker-compose.yaml as needed and uncomment the lines relating to the `nginx-proxy_default` network.

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/build` subfolder there.

The image builds upon a simple nginx webserver
and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs
to access the CouchDB database from the same domain, avoiding CORS issues.
