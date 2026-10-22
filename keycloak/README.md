# Keycloak

The shared Keycloak server for all instances ([`docker-compose.yml`](docker-compose.yml)), plus the realm
and client templates the setup scripts create each instance's realm from
([`realm_config.json`](realm_config.json), [`client_config.json`](client_config.json)).

Changing `realm_config.json` only affects newly created realms. Existing realms are brought in line by
re-running [`create-keycloak-realm.sh`](../scripts/create-keycloak-realm.sh) for them, which repairs the
settings it knows about (see its header):

```bash
./scripts/for-each-instance.sh ./scripts/create-keycloak-realm.sh
```

## Upgrading Postgres (13 → 16)

Keycloak 26.8 and later need Postgres 14 or newer and refuse to start on the former `postgres:13.2`
(`database version of at least '14.0.0'`). A new Postgres major version cannot read the old data directory,
so just changing the image tag makes the `postgres` container fail. Migrate the data with a dump and restore
**before** applying the updated `docker-compose.yml` and before moving Keycloak to 26.8. Run this in the
directory of the deployed `docker-compose.yml`:

1. Stop Keycloak (the DB keeps running) and dump the database:

   ```bash
   docker compose stop keycloak
   docker compose exec -T postgres pg_dump -U keycloak -d keycloak > keycloak-pg13.sql
   ```

2. Note a row count to compare after the restore:

   ```bash
   docker compose exec -T postgres psql -U keycloak -d keycloak -tAc 'select count(*) from user_entity'
   ```

3. Stop everything and move the old data directory aside (this is the rollback copy, don't delete it yet):

   ```bash
   docker compose down
   mv postgres postgres-pg13-backup
   ```

4. Set the `postgres` image to `postgres:16` (as in this repo's `docker-compose.yml`) and start only Postgres.
   Wait until `docker compose logs postgres` ends with `database system is ready to accept connections`:

   ```bash
   docker compose up -d postgres
   ```

5. Restore the dump into the new, empty database. The single transaction rolls back on any error, so a failed
   restore can simply be retried. Do not start Keycloak before this has finished, it would create empty tables.

   ```bash
   docker compose exec -T postgres psql -U keycloak -d keycloak -v ON_ERROR_STOP=1 --single-transaction < keycloak-pg13.sql
   ```

6. Verify the count from step 2 is unchanged, then start Keycloak:

   ```bash
   docker compose exec -T postgres psql -U keycloak -d keycloak -tAc 'select count(*) from user_entity'
   docker compose up -d keycloak
   ```

Rollback: `docker compose down`, remove the new `postgres` directory, move `postgres-pg13-backup` back to
`postgres` and set the previous image tags again. Keep the dump and the backup directory until the new setup
has proven itself.

## Upgrading Keycloak (e.g. 23 → 26)

The upgrade is an in-place upgrade of the existing Keycloak Postgres DB, migrated automatically on the first
start of the new version. It is **irreversible** (no downgrade), so back up first:

1. Stop the Keycloak container.
2. Snapshot / `pg_dump` the Keycloak Postgres volume
   (rollback = restore the snapshot + pin the previous image tag).
3. Bump the image tag (here in `docker-compose.yml`, or `charts/aam-keycloak/values.yaml` for Helm) and
   start it — the DB migrates on boot.
4. Re-run `create-keycloak-realm.sh` for all instances (see above).

Keycloak 26 specifics:

- **`sub` claim:** restored automatically — the migration adds the `basic` client scope (which carries the
  `sub` mapper) to existing clients; fresh realms get the explicit `sub` mapper from `client_config.json`.
  Exception: if a realm *already* has a `basic` client scope, Keycloak skips this — add the Subject (`sub`)
  and `auth_time` protocol mappers manually. Realms created before Keycloak 25 have no `basic` scope.
- **`exact_username`:** custom User Profile attributes are outside the automatic migration, so upgraded
  realms lose the declaration of this attribute (the entity id linked to a user account; existing values are
  kept). Step 4 re-declares it — view-able by admin + user, edit-able by admins only, since a user changing
  their own linked id would be a permission-escalation loophole. Realms without an instance directory are
  not covered by step 4; add the attribute via the Admin Console there (Realm settings → User profile).
