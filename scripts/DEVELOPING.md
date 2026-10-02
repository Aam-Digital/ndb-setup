# Developing the setup scripts

This guide is for changing or adding scripts in this folder: how a setup script is built, how a change
reaches instances that already exist (what used to be a "migration script"), and how to test it.
For what the scripts do and how to run them, see the [scripts README](README.md).

## The main rule: one definition of "correctly set up"

Every part of an instance is set up by exactly one script, and that script is also how existing instances
get fixed or updated:

| Part of an instance | Script | Re-running it on an existing instance |
| --- | --- | --- |
| Folder, `.env`, `docker-compose.yml` | `create-instance.sh` | — (`update-compose.sh` updates the compose file) |
| Keycloak realm and `app` client | `create-keycloak-realm.sh` | repairs the realm (roles, User Profile) |
| CouchDB config, databases, `_security` | `create-couchdb.sh` | re-applies the config for the current mode |
| aam-backend-service | `enable-backend.sh` | repairs the backend config |
| Other features | `enable-*.sh` | re-applies the feature's config, adds what's missing |
| Versions, compose file | `update-*.sh` | brings the instance to the given version / the canonical compose file |

So there are **no separate `migrate-*.sh` scripts**. When the correct setup changes, change the script that
creates that part so that it also brings an existing instance up to date, then roll it out:

```bash
./for-each-instance.sh --only backend ./enable-backend.sh
```

This way the first run and the repair can't drift apart: they're the same code. A migration script, on
the other hand, copies the setup logic, goes stale once it has run, and stays around to be run by mistake.

A new aam-backend-service setting with the same value on every instance doesn't need a script at all: it
gets its default in the backend's `application.yaml`, so updating the version is enough. Only an
instance-specific value or a secret needs a repair in `enable-backend.sh`. The `application.env` template
is copied once, when the backend is enabled, and never merged into an existing instance.

## Anatomy of a setup script

A skeleton showing the conventions every script follows (`create-couchdb.sh` and `enable-backend.sh` are
full examples):

```bash
#!/bin/bash
usage() {
  cat <<'EOF'
What the script sets up, in a few lines.

Usage:
  ./enable-foo.sh <instance> [--skip-restart]

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  FOO_API_TOKEN

Re-running it on an existing instance: what it repairs. For all instances:
  ./for-each-instance.sh [--only ...] ./enable-foo.sh
EOF
  exit "${1:-1}"
}

# Notes only developers need (why something is done this way) go in comments here or next to the code.

# handles --help (calls usage 0), then: setup.env, lib/common.sh, lib/secrets.sh, and
# $scriptDir / $ndbSetupDir / $baseDirectory
source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
source "$scriptDir/lib/keycloak.sh"                # other lib files only if you need them

# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

# the instance: a name or a path, asked for if missing; sets the globals $path and $org
requireInstance "${1:-}"

requireConfig FOO_API_TOKEN                        # from setup.env / environment, else Bitwarden

# ... check what is out of date, fix only that (see below) ...

if ! skipRestartNote "docker compose up -d --force-recreate foo-service" "$path"; then
  (cd "$path" && docker compose up -d --force-recreate foo-service)
fi
```

Conventions behind it:

- **`usage()` is the documentation.** It comes first, right after the shebang, so it reads like a header
  comment, and `--help` prints it. It is the only place that documents the arguments, config and re-run
  behaviour, for the operator: don't repeat that in comments. Quote the heredoc (`<<'EOF'`) and write the
  script name literally: the help runs before `lib/init.sh`, so `$baseDirectory` etc. are not set yet, and
  backticks would run as commands. `lib/init.sh` handles `-h` / `--help` in any position (before
  `--`) and before it loads `setup.env`, so the help works without one. Call `usage` (exit 1) on invalid
  arguments. Exceptions: `for-each-instance.sh` parses `--help` itself (`ownHelpFlag=true`), as arguments
  after its command belong to the command; `collect-credentials.sh` / `install-dependencies.sh` don't use
  `lib/` and check `$1` themselves.
- **Relocatable.** Build paths from `$ndbSetupDir` / `$baseDirectory` (set by `lib/init.sh` from the script's
  location), never hard-code `/var/docker` or the checkout's folder name.
- **One instance per run.** The instance is the first positional argument, so `for-each-instance.sh` can
  pass it in front of the other arguments. Don't write your own loop over instances. (Exceptions:
  `list-instances.sh` builds one combined table with `forEachInstance`, and `collect-credentials.sh` keeps its
  own loop because it is meant to be copied out and run without the rest of the checkout.)
- **Config and secrets** come from `requireConfig` / `getConfig` ([`lib/secrets.sh`](lib/secrets.sh)), never
  from `bws` directly. They read `setup.env` / the environment first and only fall back to Bitwarden when
  `BWS_ACCESS_TOKEN` is set, so scripts also run on servers without it. A new Bitwarden-backed key goes into
  `_isBwsBackedKey` (secrets are looked up by name).
- **`--skip-restart`** comes from [`lib/skip-restart.sh`](lib/skip-restart.sh), which **every** script sources
  — also the ones that restart nothing, where the flag is a no-op but must not be read as a positional
  argument. Source it at the top level (never inside a function) and before the script's own option parsing:
  sourced without arguments it sees the script's `"$@"`, sets `$skipRestart` and `set --`s the flag away.
  Guard every restart with it, so `interactive-setup.sh` can write everything first and restart once.
  Without the flag, the script restarts what it changed. `skipRestartNote <command> [dir]` returns 0 when the
  restart is to be skipped and prints what the caller has to run instead.
  Pass it on to a nested script with `${skipRestartArg[@]+"${skipRestartArg[@]}"}`.
  Three deliberate exceptions: `for-each-instance.sh` must pass the flag on to the script it runs;
  `backup.sh` rejects it, since a restore is a stop / replace the data / start cycle with nothing to skip;
  and `collect-credentials.sh` / `install-dependencies.sh` don't use `lib/` at all.
- **Exit code.** Exit non-zero when something failed. `for-each-instance.sh` lists those instances at the
  end, and a failure that's only printed gets lost in the output of a long run.
- **Output.** Say what changes (`~ updated X`, `+ added X` from the `.env` helpers); print "Nothing to do"
  when the instance is already up to date. Don't print secrets.

## Changing the setup of existing instances

Say instances need a new setting, a new Keycloak role or a corrected value. Instead of writing a migration:

1. **Find the owning script** in the table above: the one that creates that part for new instances.
2. **Write the change as a function used by both the first run and the re-run**, so there's one place that
   defines the correct value:

   ```bash
   # Write the Foo API config. Args: application.env, token
   writeFooConfig() {
     local appEnv="$1" token="$2"
     upsertEnv FOO_API_URL "https://$FOO_HOST" "$appEnv"
     upsertEnv FOO_API_TOKEN "$token" "$appEnv"
   }
   ```

3. **Add an "up to date" check** next to it. Compare against the expected values, not just "the key exists",
   so a stale or placeholder value is caught too:

   ```bash
   # Whether writeFooConfig would change nothing. Args: application.env
   fooConfigUpToDate() {
     [ "$(getVar "$1" FOO_API_URL)" == "https://$FOO_HOST" ] && ! isPlaceholderValue "$(getVar "$1" FOO_API_TOKEN)"
   }
   ```

4. **In the re-run path, collect what's out of date, then fix only that.** Change external systems (e.g.
   Keycloak) before local files, so a failure doesn't leave config pointing at something that doesn't exist.
   Save a rollback copy of each file before its first change (`saveRollbackCopy`), and restart only the
   services whose config changed.
   `repairBackendConfig` in [`enable-backend.sh`](enable-backend.sh) is the full example.

   ```bash
   if fooConfigUpToDate "$appEnv"; then
     echo "Nothing to do."
     exit 0
   fi
   saveRollbackCopy "$appEnv"
   writeFooConfig "$appEnv" "$token"
   ```

5. **Document the rollout** in the script's `usage()` and in the PR: which `for-each-instance.sh` command, which
   instances it affects, what gets restarted.
6. **Roll out** on staging first: run the command for all instances, then run it **again**. The second run
   must report "Nothing to do" everywhere; if it doesn't, the check and the write don't agree.

A one-time cleanup that no current setup produces (e.g. an old `.env` schema) has no owning script. Put it
into the script that owns the file anyway if it's cheap to detect, or do it as a manual step described in
the PR. Don't leave a script behind that breaks instances when it's run again later.

## Rules for re-running on live instances

A script that only ran once at setup time now runs on every instance, unattended. The following guards come
from real problems found while turning migrations into repairs:

- **Never create a replacement for something that should exist.** If an instance was set up with a
  Keycloak realm (its key in `.env`, or CouchDB data) and the realm is gone, stop with an error. Creating a
  new, empty realm would lock out every user. Only a definite "not found" (HTTP 404) counts as missing: a
  timeout or an error status must abort, not lead to creating it.
- **Never repoint an instance to another system.** If `.env` points to another Keycloak than `KEYCLOAK_HOST`,
  refuse instead of overwriting `KEYCLOAK_URL` (`requireCentralKeycloak`).
- **Everything that can fail happens before anything is stopped or written.** Download and validate
  templates first (`downloadBackendConfigTemplate` uses `curl -f` and checks the content), and set up the
  Keycloak clients before `docker compose down`. Before that was fixed, a failed download replaced the live
  `application.env` with an error page.
- **One failed precondition shouldn't block unrelated repairs.** If a repair can't run (e.g. the instance's
  realm is not on this Keycloak), report it, do the other repairs and exit 1 at the end.
- **Don't take a running instance down to change its config.** Reuse the running container
  (`couchdbInitStart` does), change the files, and restart only the service that has to re-read them.
- **Only ask for input that creating something needs.** A re-run must not prompt (e.g. for a locale),
  since `for-each-instance.sh` runs unattended.
- **Check the instance's own files, not the canonical template.** Instances can still have an older
  `docker-compose.yml`. Don't remove a value from `application.env` because the canonical compose file
  defines it: check the instance's compose file.
- **Leave instances alone that the change doesn't apply to.** Filter with `for-each-instance.sh --only …`
  and check `COMPOSE_PROFILES` with `profileDeploysBackend` / `profileDeploysReplicationBackend`. A
  database-only instance should come out of a backend repair untouched.

## Shell pitfalls in this code base

- **Some helpers return values in globals.** `requireInstance` sets `$path` and `$org`; `saveRollbackCopy` sets
  `$ROLLBACK_COPY`; `getKeycloakRealmKey` sets `$kid` / `$publicKey`. Copy the value into your own variable right
  after the call, before calling the next helper. The Keycloak `ensure*Client` helpers print the secret instead
  (`secret=$(ensureKeycloakBackendClient "$org") || exit 1`), with their progress on stderr.
- **A bare `return` returns the status of the previous command.** Use `return 0` for "skipped, not failed",
  or the caller counts a harmless skip as a failure.
- **`setEnv` only replaces an existing key.** When the key is missing, it prints a warning and changes
  nothing. Use `upsertEnv` unless the key must already exist.
- **`getVar` returns an empty value for a missing key.** To tell "unset" from "set to a placeholder" (like
  `NOT_USED`), use `isPlaceholderValue`.
- **`for-each-instance.sh` runs each instance in its own process**, so `exit` in your script ends only that
  instance's run. Globals don't carry over either.

## lib reference

| File | Provides |
| --- | --- |
| [`init.sh`](lib/init.sh) | sourced first by every script: handles `-h` / `--help` (calls the script's `usage 0`), sets `$scriptDir`, `$ndbSetupDir`, `$baseDirectory`, loads `setup.env`, `common.sh` and `secrets.sh` |
| [`common.sh`](lib/common.sh) | see the `.env` helpers below; `generate_password`, `saveRollbackCopy` (rollback copies of files a script changes; see `prune-rollback-copies.sh`), instance resolution (`requireInstance`, `resolveInstancePath`, `forEachInstance`), state checks (`backendEnabledCheck`, `replicationBackendEnabledCheck`, and `profileDeploysBackend` / `profileDeploysReplicationBackend` for a given `COMPOSE_PROFILES` value), `getLatestBackendVersion`, `downloadBackendConfigTemplate`, docker-compose volume-mount helpers |
| [`skip-restart.sh`](lib/skip-restart.sh) | sourced by every script after `init.sh`: the shared `--skip-restart` flag (`$skipRestart`, `skipRestartNote`) |
| [`secrets.sh`](lib/secrets.sh) | `getConfig` / `requireConfig`, and `_isBwsBackedKey` (which keys may come from Bitwarden) |
| [`couchdb.sh`](lib/couchdb.sh) | `couchdbInitStart` / `couchdbCurl` / `couchdbInitStop` / `couchdbRestart`: bring up the CouchDB init container (or reuse an already-running one), run authenticated requests, tear it down (leaving a reused one running) |
| [`keycloak.sh`](lib/keycloak.sh) | `kcApi METHOD path [json]` / `kcCreate path json` for any admin API call (they get and refresh the admin token themselves), `getKeycloakToken` (to fail early), `requireCentralKeycloak`, `getKeycloakRealmStatus`, `getKeycloakRealmKey`, `getKeycloakClientUuid` / `getKeycloakClientSecret`, `ensureKeycloakBackendClient` / `ensureCarboneRenderClient` (print the secret), `serviceAccountHasRealmManagementRole`, `getKeycloakBackendClientSecret`, `ensureBackendKeycloakAdminConfig`, `ensureAccountManagerRealmManagementRoles`, `ensureExactUsernameUserProfileAttribute` |

The `.env` helpers (they work on any `KEY=value` file, e.g. `application.env`):

| Helper | If the key is missing | If the key exists |
| --- | --- | --- |
| `getVar file KEY [fallback]` | prints the fallback (or nothing) | prints the value |
| `setEnv KEY value file` | warns, changes nothing | overwrites |
| `upsertEnv KEY value file` | adds it | overwrites |
| `ensureEnv KEY value file` | adds it | keeps the current value |
| `ensureRealValue KEY value file` | adds it | overwrites only an empty or placeholder value (`NOT_USED`, …) |
| `removeEnv KEY file` / `removeEnvIfValue KEY value file` | nothing | removes it (only with that value) |

Use `ensureRealValue` for generated values such as passwords, so a re-run never replaces them.

## Testing

Nothing here has automated tests, so test by running the script:

1. **Syntax and help:** `bash -n` on every changed file; `./x.sh --help` prints the help, also without a
   `setup.env`.
2. **Stub run.** Copy the scripts to a temp folder next to fake instances, and put fake `docker` / `curl`
   commands first on the `PATH`. To stub a lib function (e.g. a Keycloak call), append a function with the
   same name to the *copied* lib file; the later definition wins. Run with `</dev/null` so an unexpected
   prompt fails instead of hanging.

   ```bash
   T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/ndb-setup" "$T/c-acme"
   cp -r scripts "$T/ndb-setup/"
   printf 'PREFIX=c-\nKEYCLOAK_HOST=kc.example\n' > "$T/ndb-setup/setup.env"
   printf 'INSTANCE_NAME=acme\nCOMPOSE_PROFILES=full-stack\n' > "$T/c-acme/.env"
   touch "$T/c-acme/docker-compose.yml"
   printf '#!/bin/bash\necho "[docker] $*"\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
   echo 'getKeycloakToken() { token=fake; }' >> "$T/ndb-setup/scripts/lib/keycloak.sh"
   cd "$T/ndb-setup/scripts" && PATH="$T/bin:$PATH" ./for-each-instance.sh ./enable-foo.sh </dev/null
   ```

   Cover at least these cases:
   - an instance that needs the change, and one that's already up to date;
   - an instance the change doesn't apply to (another `COMPOSE_PROFILES`);
   - a failing external call: the script exits 1 and leaves no half-written config;
   - a second run, which must change nothing.
3. **Staging.** Stubs can't show how Keycloak, CouchDB or the containers really react. Run the change on one
   staging instance, then on all of them with `for-each-instance.sh`, and run it a second time.

## Checklist for a PR

- [ ] The change lives in the script that sets up that part, as a function shared by the first run and the
      re-run. No new `migrate-*.sh`.
- [ ] The re-run checks what's out of date, changes only that and says "Nothing to do" otherwise.
- [ ] It fails with a non-zero exit code, before changing anything where possible.
- [ ] It follows the rules for re-running on live instances above.
- [ ] The script's `usage()` (`--help`) documents the arguments, what a re-run repairs and the
      `for-each-instance.sh` command.
- [ ] Tested: `bash -n`, a stub run covering the cases above, and staging with a second run.
- [ ] The PR states the rollout command, which instances it affects and what gets restarted. Keep instance
      names and other production details out of it: this repository is public.
