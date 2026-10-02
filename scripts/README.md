# ndb-setup scripts

Shell scripts that provision and maintain Aam Digital instances on a server.
For the deployment walkthrough, see the [repository README](../README.md); for changing or adding scripts,
see [DEVELOPING.md](DEVELOPING.md).

**Run any script with `--help`** for its arguments, required config and what a re-run does. This page only
covers what applies to all of them. Scripts can be run from any directory.

## Directory layout

The scripts expect the `ndb-setup` checkout next to the instance folders:

```
<baseDirectory>/
├── ndb-setup/        # this repository, with setup.env (server config, read by every script)
├── c-acme/           # an instance ($PREFIX + name); its .env is the source of truth for that instance
└── c-beta/
```

## Which script to run

- **New instance:** `interactive-setup.sh` asks for everything and runs the individual steps
  (`create-*.sh`, `enable-*.sh`). It is the only script that requires Bitwarden (`BWS_ACCESS_TOKEN`).
- **Single steps, features and maintenance on an existing instance:** run the step script on its own,
  e.g. `create-keycloak-realm.sh`, `enable-backend.sh`, `update-version.sh`, `backup.sh`.

Setup scripts are safe to re-run: they keep existing files and generated secrets, skip what already exists
and repair what is out of date. Re-running the script that owns a part is also how a change of the setup is
rolled out to existing instances (there are no migration scripts).

## Selecting the instance

Scripts that work on an existing instance take it as their first argument, either as a **name**
(`$baseDirectory/$PREFIX<name>`) or as a **path** to the instance folder (`.` from inside it):

```bash
./create-couchdb.sh acme
./create-couchdb.sh /srv/instances/c-acme
```

## All instances: `for-each-instance.sh`

Runs a command once per instance, inside the instance's folder, continues on failures and lists the failed
instances at the end. A script gets the instance as its first argument; any other command runs as given:

```bash
./for-each-instance.sh ./update-version.sh ndb-core 3.5.0 3.6.0
./for-each-instance.sh --only backend ./enable-backend.sh    # only instances with aam-backend-service
./for-each-instance.sh "docker compose down && docker compose up -d"
```

## `--skip-restart`

Scripts restart the services whose config they changed. With `--skip-restart` they don't, and print the
command to run instead. Every script accepts it (`backup.sh` excepted), so it can be passed to a whole
`for-each-instance.sh` run; put it after the script:
`./for-each-instance.sh ./update-compose.sh --skip-restart`.

## Running without Bitwarden

Provide the values a script needs in `setup.env` or the environment (see
[`setup.example.env`](../setup.example.env)). If one is missing, the script says which one and how to set it:

```bash
KEYCLOAK_HOST=keycloak.example.com KEYCLOAK_USER=admin KEYCLOAK_PASSWORD=… \
  ./create-keycloak-realm.sh acme en
```
