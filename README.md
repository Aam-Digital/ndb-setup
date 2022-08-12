# Aam Digital Setup
This repository describes how to setup everything that is needed to run Aam Digital in production.
This includes deploying the app, deploying and connecting the database and optionally deploying and connecting the permission backend.

## Deploying without permission backend (simple)
To set up the application with a direct connection to the database, without a permission backend, follow these steps:

1. Clone this repository to easily get all the setup files: `git clone https://github.com/Aam-Digital/ndb-setup.git`
2. Edit the `docker-compose.yml`
   1. in `app` set `VIRTUAL_HOST` and `LETSENCRYPT_HOST` to the desired URL.
   2. in `couchdb` set `COUCHDB_PASSWORD` to secure password. This is used for admin tasks on the database.
3. Create a `config.json` file that overwrites the `session_type` and `demo_mode` settings:
   ```json
    {
      "session_type": "synced",
      "demo_mode": false
    }
   ```
4. Run `docker-compose up -d`
5. Run `./initial-setup.sh https://<VIRTUAL_HOST> <COUCHDB_PASSWORD>`
6. To add users run `js add-user.js <VIRTUAL_HOST> admin:<COUCHDB_PASSWORD> <USERNAME> <PASSWORD>` where `USERNAME` and `PASSWORD` are the desired user credentials.


## Deploying with permission backend (advanced)
Use this deployment if you want to enable permission checks in your application

1. Clone this repository to easily get all the setup files: `git clone https://github.com/Aam-Digital/ndb-setup.git`
2. Edit the `docker-compose.yml`
   1. in `app` set `VIRTUAL_HOST` and `LETSENCRYPT_HOST` to the desired URL. Set `depends_on` to `backend` and replace `COUCHDB_URL: http://couchdb:5984` with `COUCHDB_URL: http://backend:3000` (change commented out parts)
   2. Remove comments of `backend` section and set `DATABASE_PASSWORD` to a secure password. This is used for the replication process. (optional) set `SENTRY_DSN` to your [Sentry DSN](https://docs.sentry.io/product/sentry-basics/dsn-explainer/) to enable error logging. 
   3. in `couchdb` set `COUCHDB_PASSWORD` to **another** secure password. This is used for admin tasks on the database. 
3. Create a `config.json` file that overwrites the `session_type` and `demo_mode` settings:
   ```json
    {
      "session_type": "synced",
      "demo_mode": false
    }
   ```
4. Run `docker-compose up -d`
5. Run `./initial-setup.sh https://<VIRTUAL_HOST> <COUCHDB_PASSWORD> <DATABASE_PASSWORD>`
6. To add users run `js add-user.js <VIRTUAL_HOST> admin:<COUCHDB_PASSWORD> <USERNAME> <PASSWORD>` where `USERNAME` and `PASSWORD` are the desired user credentials.
7. Visit `<VIRTUAL_HOST>/db/db/_utils/` and add a `Config:Permission` document (TODO add link once documentation is deployed) to the database and define the user roles
8. Visit `<VIRTUAL_HOST>/db/api/` and execute the `POST /_session` and `POST /rules/{db}/reload` to activate the changes in the backend

# Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

This setup repository comes with a [docker compose](https://github.com/Aam-Digital/ndb-setup/blob/master/nginx-proxy.docker-compose.yml) for setting up the nginx-proxy.

1. Create the required network `docker network create nginx-proxy_default`
2. Start the required containers `docker-compose -f nginx-proxy.docker-compose.yml up -d` (this is only needed once on a server)
3. Set the `VIRTUAL_HOST`and`LETSENCRYPT_HOST` as environment variables on new docker containers to define under which URL they should be reachable

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/build` subfolder there.

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
