# ndb-setup scripts

Shell scripts that provision and maintain Aam Digital instances on a server. This document explains how
they fit together and how to run them.

- **Changing or adding a script?** See [DEVELOPING.md](DEVELOPING.md): conventions, how a change reaches
  existing instances (instead of migration scripts), helpers and testing.
- For the higher-level deployment walkthrough, see the [repository README](../README.md).

## Directory layout & assumptions

Every script assumes this on-disk layout, where the `ndb-setup` checkout sits next to the instance folders:

```
<baseDirectory>/
├── ndb-setup/                 # this repository (the checkout)
│   ├── setup.env              # server/environment config (sourced by every script)
│   ├── docker-compose.yml     # template copied into each instance
│   ├── .env.template          # template copied into each instance
│   └── scripts/
│       ├── lib/               # shared helpers (sourced, never run directly)
│       └── *.sh
├── c-acme/                    # an instance  ($PREFIX + name)
│   ├── .env                   # per-instance config — the source of truth for that instance
│   ├── couchdb.ini
│   └── ...
└── c-beta/                    # another instance
```

`baseDirectory` is the parent of the checkout, `PREFIX` (from `setup.env`, e.g. `c-`) namespaces the
instance folders, and each instance's `.env` (`INSTANCE_NAME`, `COUCHDB_*`, `COMPOSE_PROFILES`, …) is the
authoritative record for that instance.

## Architecture

### 1. Orchestrator — `interactive-setup.sh`

The entry point for creating a new instance end to end. It gathers answers (interactively or from
positional args), then **delegates each step to a standalone script**. It is the only script that
*requires* Bitwarden (`BWS_ACCESS_TOKEN`); it owns the prompts and the single final restart.

```
interactive-setup.sh
  ├─ create-dns-record.sh
  ├─ create-instance.sh
  ├─ create-keycloak-realm.sh
  ├─ create-couchdb.sh
  ├─ create-initial-user.sh
  ├─ enable-backend.sh        (optional)
  └─ enable-sentry.sh
```

### 2. Standalone step & feature scripts

Each step above is a self-contained script that can also be run on its own — e.g. to re-configure
Keycloak or recreate the databases for an existing instance. Feature toggles (`enable-backend.sh`,
`enable-notifications.sh`, `enable-email-notifications.sh`, `enable-sentry.sh`) and maintenance scripts
(`update-*.sh`, including `update-assets.sh` for a base config's asset overrides, `backup.sh`,
`prune-rollback-copies.sh`, `list-instances.sh`, …) follow the same conventions.

### 3. Shared library — `lib/`

Sourced by scripts, never executed directly. See the [lib reference](DEVELOPING.md#lib-reference).

## Running the scripts

### Instance targeting — name **or** path

Scripts that operate on an existing instance accept their `<instance>` argument as either an instance
**name** (resolved to `$baseDirectory/$PREFIX<name>`) or a **path** to the instance directory, including
`.` when run from inside the folder. `<instance>` is always the first argument. This is handled by
`requireInstance` (sets the globals `path` and `org`); the org/realm name is read from that directory's
`.env` (`INSTANCE_NAME`).

```bash
./create-couchdb.sh acme                 # by name (standard layout)
./create-couchdb.sh /srv/instances/c-acme  # by explicit path
cd /srv/instances/c-acme && …/create-couchdb.sh .   # "." from inside the folder
```

### All instances — `for-each-instance.sh`

Scripts operate on **one** instance; to run one for every instance, use the wrapper instead of a
per-script loop. It runs the command once per instance, in its own process inside the instance's directory,
keeps going on failures and lists the failed instances at the end. A script path gets the instance
directory as its first argument, before the other arguments; any other command runs as given, and a single
quoted string runs with bash:

```bash
./for-each-instance.sh ./update-compose.sh --yes
./for-each-instance.sh ./update-version.sh ndb-core 3.5.0 3.6.0     # runs update-version.sh <instance> ndb-core 3.5.0 3.6.0
./for-each-instance.sh ./enable-sentry.sh n
./for-each-instance.sh --only replication-backend ./create-couchdb.sh   # skip instances without it
./for-each-instance.sh --only backend ./enable-backend.sh               # skip instances without aam-backend-service
./for-each-instance.sh docker compose pull
./for-each-instance.sh "docker compose down && docker compose up -d"    # restart all instances
```

Exceptions: `list-instances.sh` builds one combined table (with `forEachInstance`), and
`collect-credentials.sh` keeps its own loop (self-contained, see below).

### Migrations are repairs of the setup scripts

There are no separate migration scripts: when the setup of an instance changes, the setup script that
creates that part also repairs existing instances when re-run (see the notes below), and the change is
rolled out with `for-each-instance.sh`. See [DEVELOPING.md](DEVELOPING.md#changing-the-setup-of-existing-instances).

### Re-running, `--skip-restart`

Scripts are safe to re-run: they keep existing files and generated secrets, and skip what already exists.
Scripts that write config of a running stack restart what they changed, unless `--skip-restart` is passed
(then restart the instance yourself — the script prints the command to run, e.g. `docker compose up -d` in
its folder).

`--skip-restart` is accepted by every script, in any argument position, from the shared
[`lib/skip-restart.sh`](lib/skip-restart.sh) — including the scripts that restart nothing, where it is simply
ignored, so it can be passed to a whole `for-each-instance.sh` run without knowing which scripts restart.
Put it after the script, where `for-each-instance.sh` passes it on
(`./for-each-instance.sh ./update-compose.sh --skip-restart`); before the script it is rejected as an
unknown option of `for-each-instance.sh` itself. `backup.sh` rejects the flag, because restoring a backup
has to stop and start the instance, and the self-contained `collect-credentials.sh` /
`install-dependencies.sh` don't use `lib/` at all.

## Script notes

Each script documents its own arguments and purpose in a header comment — run `head -n 20 <script>.sh` or
open the file. Rather than duplicate that here, these notes cover only what needs extra context:

- **`backup.sh`** creates, lists and restores the encrypted system backups (`create` is the default, for
  cron; see the [repository README](../README.md#backups)). Not to be confused with the rollback copies
  scripts save before changing a file, which `prune-rollback-copies.sh` deletes.
- **`collect-credentials.sh`** is intentionally self-contained (meant to be copied out; takes an
  `INSTANCES_DIR` arg, default `/var/docker`) and does not source `lib/`.
- **`enable-backend.sh`** re-run on an instance with the backend already enabled does not abort but only
  repairs its config with the same functions the first run uses: the Keycloak admin access (realm-management
  roles incl. `manage-clients`, `KEYCLOAK_*` in `application.env`), replication-backend's permission-check
  client and CouchDB credentials, and the Carbone render API client. It recreates only the services whose
  config changed. For every instance with the backend: `./for-each-instance.sh --only backend ./enable-backend.sh`.
- **`create-couchdb.sh`** is safe to re-run on a live instance and doubles as the repair for CouchDB's
  security config: it detects the mode from `COMPOSE_PROFILES`, reuses a running CouchDB (restarting it only
  if `couchdb.ini` changed) and re-applies `_security`, the JWT config and — with replication-backend —
  rejecting anonymous requests. For every instance with replication-backend:
  `./for-each-instance.sh --only replication-backend ./create-couchdb.sh`.
- **`create-keycloak-realm.sh`** re-run on an existing instance reuses its realm and repairs what older
  realm templates lack: the realm-management roles of `account_manager` (for the app's role admin UI) and
  the admin-only `exact_username` User Profile attribute (lost by realms upgraded in place to Keycloak 26,
  see [`keycloak/README.md`](../keycloak/README.md)). It refuses to create a new realm for an instance that
  was already set up, or to repoint one using another Keycloak. For every instance:
  `./for-each-instance.sh ./create-keycloak-realm.sh`.
- **`enable-notifications.sh`** writes the frontend Firebase web config to the instance's
  `assets/firebase-config.json` and volume-mounts it (the published ndb-core image does not contain it).
  Without BWS, provide `FIREBASE_CONFIG_JSON` as a single-quoted JSON object in `setup.env`. Re-running
  the script on an instance with notifications already enabled only adds a missing web config/mount.

## Running without Bitwarden

Provide the values the script needs in `setup.env` or the environment (see
[`setup.example.env`](../setup.example.env)); then any converted script runs without a token:

```bash
KEYCLOAK_HOST=keycloak.example.com KEYCLOAK_USER=admin KEYCLOAK_PASSWORD=… \
  ./create-keycloak-realm.sh /srv/instances/c-acme en
```

If a required value is missing, `requireConfig` prints exactly which one and how to supply it.
