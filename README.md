# Aam Digital Setup
This repository describes how to set up everything that is needed to run Aam Digital in production.
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
7. Visit `<VIRTUAL_HOST>/db/db/_utils/` and add a `Config:Permission` document to the database and define the user roles ([read more](https://aam-digital.github.io/ndb-core/documentation/additional-documentation/concepts/user-roles-and-permissions.html))
8. Visit `<VIRTUAL_HOST>/db/api/` and execute the `POST /_session` and `POST /rules/{db}/reload` to activate the changes in the backend

# Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

This setup repository comes with a [docker compose](https://github.com/Aam-Digital/ndb-setup/blob/master/nginx-proxy/docker-compose.yml) for setting up the nginx-proxy.

1. Create the required network
   > docker network create nginx-proxy_default
2. In `nginx-proxy/docker-compose.yml` set `DEFAULT_EMAIL` to a valid email address
3. Start the required containers (this is only needed once on a server)
   > cd nginx-proxy && docker-compose up -d  
4. Set the `VIRTUAL_HOST`and`LETSENCRYPT_HOST` as environment variables on new docker containers to define under which URL they should be reachable

# (optional) User management in Keycloak
The system supports the [Keycloak](https://www.keycloak.org/) identity management system.
This is optional but allows to enable further features like password reset in the application.
To enable this follow the following steps.

## Setup

To start the required docker containers execute the following (this is only needed once on a server):
1. In `keykloak/docker-compose.yml` set `KC_DB_PASSWORD` and `POSTGRES_PASSWORD` to the same **secure** password
2. Change `example.aam-digital.com` to the **same** valid url where the Keycloak can later be reached publicly, see the [nginx section](#deploying-under-a-domain-name-using-nginx-proxy) for more details
3. Start the required containers
   > cd keycloak && docker-compose up -d

## Add an instance

To add an application to the Keycloak execute the following:

1. Open `realm_config.json` and add the required settings for you email server to enable Keycloak to send emails in your name
2. Open `create_realm.sh` and set the `<DOMAIN>` to the general domain name of you applications (e.g. `aam-digital`)
3. User `docker ps` to get the ID of the Keycloak container
4. Run the script `create_realm.sh` with the container ID, the Keycloak admin password and the name of the application
5. Go the admin UI of your Keycloak
6. Navigate to the realm with the name of the application (`/admin`)
7. Click on _Clients_ > _app_ > _Action_ > _Export_
8. Place this file in the assets folder of the application with the name `keycloak.json`. It might be necessary to mount the file as a volume into the docker container.
9. Update the `config.json` of the application to enable Keycloak as the authenticator:
   ```json
   {
      "session_type": "synced",
      "demo_mode": false,
      "authenticator": "keycloak"
    }
   ```
10. (optional) Migrate existing users from CouchDB to Keycloak by running
   > node migrate-users.js <COUCHDB_URL> <COUCHDB_ADMIN_PASSWORD> <KEYCLOAK_URL> <KEYCLOAK_ADMIN_PASSWORD> <REALM_NAME>

### Further steps

To enable authentication with the CouchDB/backend follow the one that fits your setup.

#### When using CouchDB directly (no permission backend)

1. (optional) Checkout the latest `couchdb.ini`: `git checkout origin/master -- couchdb.ini`
2. Go to _Realm Settings_ > _Keys_
3. From the `RSA256` entry use `Kid` as `<KID>` in the `couchdb.ini` file, place the public key where it says `<PUBLIC_KEY>` and uncomment this line
4. Run `docker-compose stop && docker-compose up -d`
5. The application is now connected with Keycloak

#### When using the permission backend

1. Go to _Realm Settings_ > _Keys_
2. From the `RSA256` entry click on *Public key* and copy the shown key
3. Go to the `docker-compose.yml` file
4. In the section *backend* > *environment* add the following line
   ```yaml
   JWT_PUBLIC_KEY: "-----BEGIN PUBLIC KEY-----\n<KEY_FROM_STEP_2>\n-----END PUBLIC KEY-----"
   ```
5. Save the file and run `docker-compose up -d`

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/build` subfolder there.

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
