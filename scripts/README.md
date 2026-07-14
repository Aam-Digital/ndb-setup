# ndb-setup scripts

Shell scripts that provision and maintain Aam Digital instances on a server. This document explains how
they fit together so both **developers** (extending them) and **admins** (running them) can work with
confidence.

For the higher-level deployment walkthrough, see the [repository README](../README.md); this file focuses
on the scripts' architecture and shared conventions.

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
`enable-feature-notification.sh`, `enable-feature-notification-email.sh`, `enable-assets-overwrites.sh`)
and maintenance/migration scripts follow the same conventions.

### 3. Shared library — `lib/`

Sourced by scripts, never executed directly. See [lib reference](#lib-reference) below.

## Shared conventions

Every non-trivial script follows these. When you write a new one, follow them too.

### Standard header (relocatable — no hard-coded paths)

`baseDirectory` is **derived from the script's own location**, never hard-coded, so the checkout can live
anywhere:

```bash
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/secrets.sh"   # if it needs secrets
```

Root-level scripts (one directory up, in the checkout root) use `baseDirectory="$(cd "$scriptDir/.." && pwd)"`.

### Config & secrets — `getConfig` / `requireConfig`

Scripts never call `bws` directly. They resolve values through [`lib/secrets.sh`](lib/secrets.sh), which
**hides where a value comes from**:

1. an already-set environment variable / `setup.env` value, else
2. the Bitwarden Secrets Manager — **only** when `BWS_ACCESS_TOKEN` is set and the key has a known UUID.

```bash
requireConfig KEYCLOAK_HOST      # aborts with a clear message if unresolved; exports $KEYCLOAK_HOST
value=$(getConfig SMTP_SERVER)   # returns non-zero if unresolved (caller decides)
```

**Consequence:** the standalone scripts run **without BWS** — just put the needed values in `setup.env`
or the environment. Only `interactive-setup.sh` (and the not-yet-converted one-off migrations) require a
token. To add a new BWS-backed value, add its `NAME → UUID` mapping to `_bwsSecretId` in `lib/secrets.sh`.

### Instance targeting — name **or** path

Scripts that operate on an existing instance accept their `<instance>` argument as either an instance
**name** (resolved to `$baseDirectory/$PREFIX<name>`) or a **path** to the instance directory, including
`.` when run from inside the folder. This is handled by `resolveInstancePath` (sets the global `path`);
the org/realm name is then read from that directory's `.env` (`INSTANCE_NAME`).

```bash
./create-couchdb.sh acme                 # by name (standard layout)
./create-couchdb.sh /srv/instances/c-acme  # by explicit path
cd /srv/instances/c-acme && …/create-couchdb.sh .   # "." from inside the folder
```

`forEachInstance <callback> [instance]` iterates every instance, or a single one (name or path) when the
argument is given.

### Idempotency

Scripts are safe to re-run. They preserve existing files and generated secrets (never regenerate a
CouchDB password or bump a pinned version on re-run — see `ensureRealValue`), skip already-created
Keycloak realms/clients/users and CouchDB databases, and only send onboarding email on first creation.

### `--skip-restart`

Feature scripts that write config accept `--skip-restart` so an orchestrator can write all config first
and restart the stack **once** at the end. Run standalone (without the flag) they restart themselves.

## lib reference

| File | Provides |
| --- | --- |
| [`common.sh`](lib/common.sh) | `.env` helpers (`getVar`, `setEnv`, `upsertEnv`, `ensureEnv`, `ensureRealValue`, `removeEnv`), `generate_password`, `backupFile`, instance resolution (`resolveInstancePath`, `forEachInstance`), state checks (`backendEnabledCheck`, `replicationBackendEnabledCheck`), `getLatestBackendVersion`, docker-compose volume-mount helpers |
| [`secrets.sh`](lib/secrets.sh) | `getConfig` / `requireConfig` and the `NAME → BWS UUID` map (`_bwsSecretId`) |
| [`couchdb.sh`](lib/couchdb.sh) | `couchdbInitStart` / `couchdbCurl` / `couchdbInitStop` — bring up the database-only CouchDB init container, run authenticated requests, tear it down |
| [`keycloak.sh`](lib/keycloak.sh) | `getKeycloakToken`, `getKeycloakRealmKey`, `createKeycloakBackendClient`, `serviceAccountHasRealmManagementRole` |

Each script documents its own arguments and purpose in a header comment — run `head -n 20 <script>.sh` or
open the file. Rather than duplicate that here, note only the deviations from the conventions above:

- **One-off migrations** (`migrate-*.sh`) have their `baseDirectory` derived but still load secrets
  directly from BWS; they are kept as historical one-offs, not converted to `getConfig`.
- **`backup.sh` / `backup-restore.sh`** still target `/var/docker` for the actual backup data path (the
  tar and restore paths are coupled), so they are not relocatable for the backup operation itself.
- **`collect-credentials.sh`** is intentionally self-contained (meant to be copied out; takes an
  `INSTANCES_DIR` arg, default `/var/docker`) and does not source `lib/`.
- **`enable-feature-notification.sh`** still needs BWS for a *fresh* Firebase config (Firebase is JSON,
  not a scalar `getConfig` can resolve).

## Running without Bitwarden

Provide the values the script needs in `setup.env` or the environment (see
[`setup.example.env`](../setup.example.env)); then any converted script runs without a token:

```bash
KEYCLOAK_HOST=keycloak.example.com KEYCLOAK_USER=admin KEYCLOAK_PASSWORD=… \
  ./create-keycloak-realm.sh /srv/instances/c-acme en
```

If a required value is missing, `requireConfig` prints exactly which one and how to supply it.

## Adding a new script

1. Start from the [standard header](#standard-header-relocatable--no-hard-coded-paths); source only the
   lib files you use.
2. Take the instance as `$1`; resolve it with `resolveInstancePath` and read the org from
   `getVar "$path/.env" INSTANCE_NAME` (or accept a name for creation-time scripts).
3. Resolve any secret with `requireConfig NAME` (add its UUID to `lib/secrets.sh` if BWS-backed).
4. Make every effect idempotent (guard creates, use `ensureRealValue` for generated values).
5. If it writes config for a running stack, support `--skip-restart`.
6. Document its arguments and purpose in a header comment (the single source of truth for per-script docs).
