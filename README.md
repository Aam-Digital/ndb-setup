# Aam Digital Setup
This repository describes how to set up everything that is needed to run the [Aam Digital case management system](https://www.aam-digital.com) in production.
This includes deploying the app, deploying and connecting the database and optionally deploying and connecting the permission backend and keycloak.

*The source code of the actual application, as well as instructions to run it on your local machine during development, can be found in the [Aam-Digital/ndb-core](https://github.com/Aam-Digital/ndb-core) repository.*

## Systems requirements
The deployment works with minimal requirements. 
All you need is a system that runs [Docker](https://www.docker.com/) and allows to reach endpoints through a public URL.
For a single instance a server with **2GB RAM**, a **single CPU** and **20GB disc space** is sufficient.
With more data and/or more deployments more RAM and CPU power might be necessary or the sync could start to become very slow.
The required disc space scales with the amount of data and especially images and attachments that are saved in the application.

To monitor the hardware usage [this repo](https://github.com/Aam-Digital/monitoring/blob/main/docker-compose.yml) contains a Prometheus setup.
This can be connected with [Grafana](https://grafana.com/) to create a system dashboard and trigger alerts on critical performance.

## Deploying the application
The interactive script `interactive_setup.sh` walks you through the process of setting up new applications.
Running the setup script will create a new folder in the same parent folder, next to the cloned repo. You can use the script multiple times to create new instances.

1. Clone this repository
2. Edit the `interactive_setup.sh` script and review the variables where necessary (see below "Adjusting the script")
3. Then run the script and follow the questions in the console
   > ./interactive_setup.sh

The following things can be automatically done

1. Deploy the application
2. (optional) add the permission backend
3. (optional) connect with a running Keycloak
4. (optional) migrate users from CouchDB to Keycloak

To log errors with [Sentry](https://sentry.io/), simply set the variable `SENTRY_DSN` in the `.env` file to you sentry DSN.

## Adjusting the script
Some things might need to be adjusted based on how you environment looks.
Have a look at the comments at the beginning of the file `interactive_setup.sh`

1. Domain name for the final applications (variable `domain`)
2. Prefix for created folders (variable `prefix`)
3. Location of the `.env` file of the keycloak deployment (see section [User management in Keycloak](#user-management-in-keycloak))

# Deploying under a domain name using nginx-proxy
In order to make the application's docker container accessible under a public URL, you need to expose it using a tool of your choice.
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
See the `/build` sub folder there.

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
