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
