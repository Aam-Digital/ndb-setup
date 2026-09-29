# AI Agent Instructions

Docker-based deployment and infrastructure setup for [Aam Digital](https://github.com/Aam-Digital/ndb-core) instances.
See README.md for setup and usage details.

## Public GitHub Content (PRs, Issues, Comments, Commit Messages)

This repository is public. Never include customer/project-identifying information or other
production-system-specific data in anything posted to GitHub — no deployment/instance names,
server hostnames, external partner URLs, user identifiers, or real record data. Share only
generalized insights instead (e.g. "a large production instance", "an external webhook
consumer"). Scrub quoted log or monitoring output before posting. Links to access-restricted
internal tools (e.g. Sentry issues) are acceptable.

## Scripts

Follow [scripts/DEVELOPING.md](scripts/DEVELOPING.md) when changing or adding scripts. In particular:

- Don't add `migrate-*.sh` scripts: make the setup script that owns that part repair existing instances
  when re-run.
- Config and secrets: never call the `bws` (Bitwarden Secrets Manager) CLI directly. Scripts source
  `scripts/lib/init.sh` (which loads `lib/common.sh` and `lib/secrets.sh`) and resolve values with
  `requireConfig KEY` / `getConfig KEY`. These take the value from `setup.env` / the environment first and
  only fall back to Bitwarden when `BWS_ACCESS_TOKEN` is set, so scripts also work on servers without the
  `bws` CLI or a token. New Bitwarden-backed keys must be added to `_isBwsBackedKey` in `secrets.sh`
  (secrets are looked up by name, not by ID).
