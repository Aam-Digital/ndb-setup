# Aam Digital Setup
This repository describes how to set up everything that is needed to run Aam Digital in production.
This includes deploying the app, deploying and connecting the database and optionally deploying and connecting the permission backend and keycloak.

## Deploying the application
The interactive script `interactive_setup.sh` walks you through the process of setting up new applications.

1. Just clone this repository
2. Then run the script and follow the questions in the console
   > ./interactive_setup.sh

The following things can be automatically done

1. Deploy the application
2. (optional) add the permission backend
3. (optional) connect with a running Keycloak
4. (optional) migrate users from CouchDB to Keycloak

To log errors with [Sentry](https://sentry.io/), simply set the variable `SENTRY_DSN` in the `.env` file to you sentry DSN.

## Adjusting the script
Some things might need to be adjusted based on how you environment looks.
Have a look at the following things

1. How does the folder translate into the application name (variable `org`)
2. Domain name for the final applications (variable `url`)
3. Location of the `.env` file of the keycloak deployment (see section [User management in Keycloak](#user-management-in-keycloak))

# Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

This setup repository comes with a [docker compose](https://github.com/Aam-Digital/ndb-setup/blob/master/nginx-proxy/docker-compose.yml) for setting up the nginx-proxy.

1. Create the required network
   > docker network create nginx-proxy_default
2. In `nginx-proxy/docker-compose.yml` set `DEFAULT_EMAIL` to a valid email address
3. Start the required containers (this is only needed once on a server)
   > cd nginx-proxy && docker-compose up -d  
4. Set the `VIRTUAL_HOST`and`LETSENCRYPT_HOST` as environment variables on new docker containers to define under which URL they should be reachable

# User management in Keycloak
The system supports the [Keycloak](https://www.keycloak.org/) identity management system.
This is optional but allows to enable further features like password reset in the application.
To enable this follow the following steps.

To start the required docker containers execute the following (this is only needed once on a server, you can skip these steps if you just want to add another Aam Digital instance to an existing keycloak server):
1. Open the file `keycloak/.env`
2. Set the password variables to secure passwords and assign valid urls for the Keycloak and [account backend](https://github.com/Aam-Digital/account-backend) (without `https://`)
3. Open `keykloak/realm_config.json` and add the required settings for you email server to enable Keycloak to send emails in your name
4. Open `keykloak/create_realm.sh` and set the `<DOMAIN>` to the general domain name of you applications (e.g. `aam-digital`)
5. Start the required containers
   > cd keycloak && docker-compose up -d

Once done, applications can be connected with Keycloak through the `interactive_setup.sh`.

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/build` subfolder there.

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
