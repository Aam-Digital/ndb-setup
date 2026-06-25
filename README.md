# Aam Digital Setup
This repository describes how to set up everything that is needed to run the [Aam Digital case management system](https://www.aam-digital.com) in production.
This includes deploying the app, deploying and connecting the database and optionally deploying and connecting the permission backend and keycloak.

*The source code of the actual application, as well as instructions to run it on your local machine during development, can be found in the [Aam-Digital/ndb-core](https://github.com/Aam-Digital/ndb-core) repository.*

(!) copy the example.* files (e.g. setup.example.env) and add your actual variables and config


## Systems requirements
The deployment works with minimal requirements. 
All you need is a system that runs [Docker](https://www.docker.com/) and allows to reach endpoints through a public URL.
For a single instance a server with **2GB RAM**, a **single CPU** and **20GB disc space** is sufficient.
With more data and/or more deployments more RAM and CPU power might be necessary or the sync could start to become very slow.
The required disc space scales with the amount of data and especially images and attachments that are saved in the application.

A Keycloak server is required for user management and login.
See below to run the Keycloak included here in this setup sample.

To monitor the hardware usage [this repo](https://github.com/Aam-Digital/monitoring/blob/main/docker-compose.yml) contains a Prometheus setup.
This can be connected with [Grafana](https://grafana.com/) to create a system dashboard and trigger alerts on critical performance.

## Deploying the application
The interactive script `interactive_setup.sh` walks you through the process of setting up new applications.
Running the setup script will create a new folder in the same parent folder, next to the cloned repo. You can use the script multiple times to create new instances.

1. Clone this repository
2. Set up local environment by copying setup.example.env file and editing the `setup.env` and `keyloak/.env`
3. Then run the script and follow the questions in the console to generate the required .env and other files:
   > ./interactive_setup.sh

The following things can be automatically done

1. Deploy the application
2. (optional) add the permission backend
3. (optional) connect with a running Keycloak
4. (optional) migrate users from CouchDB to Keycloak

To log errors with [Sentry](https://sentry.io/), simply set the variable `SENTRY_DSN` in the `.env` file to you sentry DSN.

## Adjusting the script
Some things have to be set for the interactive setup script through environment variables.
Have a look at `interactive_setup.sh` to see which .env files are loaded there.

1. Domain name for the final applications (variable `domain`)
2. Prefix for created folders (variable `prefix`)
3. the `.env` file of the keycloak deployment (see section [User management in Keycloak](#user-management-in-keycloak))

## Enabling API Modules
The [scripts folder](./scripts/) provides utilities to enable the backend and its specific API modules.
Check the documentation in the comments at the top of each file for usage instructions.


-----

## Admin CLI (migrations, statistics, CouchDB operations)

Admin operations such as running config migrations, checking for conflicts, and collecting statistics are performed locally using the **ndb-core CLI** — no deployed admin service is required.

### Workflow

1. On the server, run the credential collector script to gather CouchDB passwords for all instances:

   ```bash
   ./scripts/collect-credentials.sh [INSTANCES_DIR]
   # output: credentials.json in the current directory
   ```

2. Copy `credentials.json` to your local ndb-core checkout (it is git-ignored there).

3. Run CLI commands from your ndb-core checkout:

   ```bash
   npm run cli -- check                                        # verify connectivity
   npm run cli -- migrate list                                 # list available migrations
   npm run cli -- migrate run latest-config-formats --dry-run # preview changes
   npm run cli -- migrate run latest-config-formats           # apply with confirmation
   npm run cli -- statistics --format csv > stats.csv         # export statistics
   ```

See [cli/README.md](https://github.com/Aam-Digital/ndb-core/blob/master/cli/README.md) in the ndb-core repository for the full command reference.


-----
# Deploying under a domain name using swag-proxy
In order to make the application's docker container accessible under a public URL, you need to expose it using a tool of your choice.
The system works well with the [swag-proxy](https://docs.linuxserver.io/general/swag/). This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

This setup repository comes with a [docker compose](https://github.com/Aam-Digital/ndb-setup/blob/master/swag-proxy/aam-prod-2/docker-compose.yml) for setting up the swag-proxy. (we have multiple production instances, so as an example the aam-prod-2 config)

1. Create the required network
   > docker network create external_web
2. In `swag-proxy/<server>/docker-compose.yml` set `EMAIL` to a valid email address and adapt the DOMAINS config to match your setup. 
2. In `swag-proxy/<server>/config/dns-conf/` create a new `hetzner-cloud.ini` file from the example file and add your API token
   (required for DNS authentication of certbot when creating new SSL certificates)
3. Start the required containers (this is only needed once on a server)
   > cd nginx-proxy && docker-compose up -d  


-----
# User management in Keycloak
The system uses the [Keycloak](https://www.keycloak.org/) identity management system.
All the required configuration can be found in the `keycloak` folder.

We use a custom build of Keycloak that includes certain plugins required for 2-Factor-Auth.
Plugin versions are managed within that custom docker image in [Aam-Digital/aam-cloud-infrastructure](https://github.com/Aam-Digital/aam-cloud-infrastructure).

To start the required docker containers execute the following (this is only needed once on a server, you can skip these steps if you just want to add another Aam Digital instance to an existing keycloak server):
1. Open the file `keycloak/.env`
2. Set the password variables to secure passwords and assign valid urls for the Keycloak (without `https://`)
3. Start the required containers
   > cd keycloak && docker-compose up -d

Once done, applications can be connected with Keycloak through the `interactive_setup.sh`.

`keycloak/realm_config.json` provides a sample configuration that the interactive setup script uses (replacing some placeholders automatically).
You can create a custom realm_config.json in each baseConfig folder to overwrite this.

## Upgrading Keycloak (23 → 26)

Keycloak 25+ no longer adds the `sub` claim to access tokens by default, and from this version the
templates declare `exact_username` as an admin-only User Profile attribute. The upgrade is supported
as an in-place upgrade of the existing Keycloak Postgres database.

> **⚠️ Back up first — the upgrade is irreversible.**
> On the first start of the Keycloak 26 container the Postgres schema is migrated automatically
> (there is no downgrade). Before upgrading any instance:
> 1. Stop the Keycloak container.
> 2. Snapshot / `pg_dump` the Keycloak Postgres volume.
> 3. Start the new version — the migration runs by itself, no manual step.
>
> Rollback = restore the snapshot and pin the previous image tag.

Steps:
1. Back up the Keycloak Postgres data (above).
2. Bump the image tag to the Keycloak 26 build of `aam-keycloak` (see `keycloak/docker-compose.yml`,
   and `charts/aam-keycloak/values.yaml` for Helm deployments).
3. Start Keycloak — the database migrates automatically on boot.

After the upgrade:
- **`sub`**: restored automatically. The migration adds the `basic` client scope to existing clients
  (which carries the `sub` mapper), so the `app` client keeps emitting `sub` with no manual change.
  For freshly created realms, the explicit `sub` mapper in `client_config.json` provides it.
  > ⚠️ **Exception:** if the realm **already has** a client scope named `basic`, Keycloak **skips**
  > this automatic migration — you must then add the Subject (`sub`) and `auth_time` protocol mappers
  > to the client/scope manually. Realms created before Keycloak 25 have no `basic` scope, so the
  > automatic path applies to them.
- **`exact_username`**: existing values are preserved and keep working. To make it **admin-only
  editable**, the User Profile declaration from `realm_config.json` must be applied to the existing
  realm (it is not retro-applied by the migration) — via the Admin Console
  (*Realm settings → User profile*) or by re-importing the realm configuration.

## 2-Factor-Auth
Keycloak supports a second login factor through the methods described below:
- Authenticator App
- E-Mail OTP

### Authenticator app OTP
The only built-in second factor ist OTP using a Authenticator app.
This can be enabled by editing a specific user in the Keycloak "Administration Console" and adding the `Configure OTP` in the "Required user actions".
It can also be activated for everyone by changing the `Browser - Conditional OTP` in the used Browser flow from `Conditional` to `Required`.

### Email OTP
Through 3rd party libraries OTP via Email is supported.
This also comes with the option to trust the device for a configured time period (during which you do not have to enter the OTP when logging in).

To enable this feature visit `<KEYCLOAK_URL>/admin/master/console/#/<REALM>/authentication/` (i.e. open the "Authentication" section of the Keycloak realm) and follow the described steps below ("Activating Email 2FA").
If you created this realm using a recent version of the `realm_config.json` then you should find a flow with the name `Email 2FA`,
otherwise see the steps below in the next section ("Setting up Email OTP manually").

#### Activating Email 2FA
To activate 2FA over email, click on the 3 dot menu on the right of the `Email 2FA` flow and select `Bind flow` and select `Browser flow`.
After saving, when trying to log in to the app you should be asked to enter the OTP which has been sent to the email that is associated with the username.

#### Deactivating Email 2FA
Similar to the steps of activating the 2FA flow, to disable it you need to re-activate the normal "browser" flow:
Click on the 3 dot menu on the right of the `browser` flow, select `Bind flow` and then select `Browser flow`.

_Disabling 2FA for a specific account can be configured but is not part of default setup yet. Please check with existing sample systems for the setup to make the following instructions work:_
> To disable email 2FA for only one individually user assign the Keycloak User Role "no-email-2fa" to that user account to skip 2FA for that person.
> If the role does not exist yet, create it in the Keycloak Admin interface.
> (The logic of this special role is configured within the `Email 2FA` Authentication flow as a condition)


#### Setting up Email OTP manually
If the `Email 2FA` flow is not available in the realm (section "Authentication"), you can configure it manually:

1. Click on the 3 dot menu of the `browser` flow and select duplicate
2. Enter `Email 2FA` as name
3. Delete the last two steps (`Condition - user configured` and `OTP form`)
4. Click on the `+` button in the last row (`Email 2FA Browser - Conditional OTP`)
5. Select `Add condition`, there select `Condition - Device Trusted` and click `Add`
6. On the new step (`Condition - Device Trusted`) click on `Disabled` and change it to `Required`
7. Click on the cog icon next to `Required` and enter `trusted-config` as `Alias` and click `Save`
8. Again click on the `+` icon for `Email 2FA Browser - Conditional OTP`
9. Select `Add step`, there select `Email OTP` and click `Add`
10. Change `Disabled` to `Required` for `Email OTP`
11. Again click on the `+` icon for `Email 2FA Browser - Conditional OTP`
12. Select `Add step`, there select `Register Trusted Device` and click `Add`
13. Change `Disabled` to `Required` for `Register Trusted Device`

Now the flow is configured correctly, and you can start using it the same way it has been described above.

In the step `Email OTP` you can configure the amount of seconds for which an OTP is valid and in the `Register Trusted Device` step you can configure how long a device will be trusted (e.g. `P30d` for 30 days or `PT24h` for 24 hours).

### Further options
There are many ways in which the authentication flow can be configured.
For example, you could also add the trust device step to the OTP with authenticator app, or you could make the user decide which OTP (email or app) should be used.
Consult the [Keycloak docs](https://www.keycloak.org/docs/latest/server_admin/index.html#_authentication-flows) for ways to edit flows or configure new ones.


-----
# API Integrations and SQL Reports
It is possible to calculate reports for the app's data using SQL queries.
For details information, check our [Report documentation](http://aam-digital.github.io/ndb-core/documentation/additional-documentation/how-to-guides/create-a-report.html)

## Set up API Integration
(e.g. with TolaData)

1. Enable the reporting backend:
    - add `aam-backend-service` to you COMPOSE_PROFILES .env variable to activate that container in the docker compose: `COMPOSE_PROFILES=replication-backend,aam-backend-service`
    - add `AAM_BACKEND_SERVICE_URL=http://aam-backend-service:3000` to the .env file that feeds into the docker-compose.yml
2. Set up Reporting API according to [aam-services README](https://github.com/Aam-Digital/aam-services/blob/main/README.md)
    - (re-up the docker compose and confirm the new containers are running)
    - follow instructions there to set up an auth client to access results via API


-----
# Backups
Basic backup scripts are available in the "scripts" folder.

Set the setup.env variables for the backup root folder and passphrase (to encrypt backups).
Then run the `backup.sh` script to create a current backup.

### Scheduled regular backups
You can set up the script to run via cron:

Start the new cron job
```bash
crontab -e
# then enter the following (adjusted to your actual file locations)
0 2 * * *       /var/docker/ndb-setup/backup.sh 
# the above runs every day at 2 am 
```

### Restoring a backup
Under `/var/docker` run the interactive script `backup-recover.sh` to load a backup for a certain client from a certain date. 

To manually load a backup follow these steps:
1. Find the passphrase in the `/var/docker/backup.sh` file.
2. Go to `mnt/<backup-volume>/backups`
3.  Decrypt a backup using
	```bash
	gpg --passphrase \<passphrase\> -o output -d \<backup-file\>
	```
4. Decompress the backup
	```bash
	mkdir ./unpacked && tar -xzvf output --directory ./unpacked
	```
5. Go to application where backups should be applied and stop docker container
	```bash
	cd /var/docker/ndb-\<instance\>
	docker compose down
	```
6. Load the backup
	```bash
	mv couchdb couchdb_old && mv ~/backups/unpacked/var/docker/ndb-\<instance\>/couchdb ./couchdb
	```
7. Start the docker containers
	```bash
	docker compose up -d
	```
8. After everything works as expected, delete all temporary data
	```bash
	rm -rf couchdb_old ~/backups/output ~/backups/unpacked
	```

When applying a backup, do not forget to clear you browser cache before opening the application again. Otherwise the previously corrupted data will be synced from the browser to the DB that has just been backed up. To delete all local data go to `https://<instance>.aam-digital.com/support` and press `Reset Application`. All users, which have corrupted data will need to do this.

More information on CouchDB backups can be found [here](https://docs.couchdb.org/en/latest/maintenance/backups.html).



-----
# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/build` sub folder there.

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
