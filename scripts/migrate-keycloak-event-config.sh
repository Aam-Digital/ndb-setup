#!/bin/bash

# Migration script: turn on the Keycloak login/admin event store in every realm
# (authentication-failure monitoring follow-up).
#
# Why:
#   Authentication monitoring has two halves, and they live in different places:
#
#     1. METRICS — "are we being attacked right now?"
#        Aggregate counters, scraped by Prometheus and alerted on in Grafana.
#        Produced by the Keycloak image (keycloak-aam sets
#        KC_METRICS_ENABLED + KC_EVENT_METRICS_USER_ENABLED at build time, since
#        both are Keycloak BUILD TIME options) and served on the management port
#        9000 at /metrics. Nothing to configure per realm.
#
#     2. EVENTS — "who was attacked, from which IP, on which client?"
#        Individual, per-user records in Keycloak's own Postgres, visible under
#        Realm settings -> Sessions/Events and via the Admin API. A metric can
#        only ever tell you a count; the event store is what makes an incident
#        investigable after the fact. THIS is what the script configures.
#
#   Event storage is off by default in Keycloak and is a PER-REALM setting, so
#   with realm-per-instance it has to be applied to every realm. Fresh realms
#   get it from keycloak/realm_config.json; this script covers the realms that
#   already exist (including ones without an instance dir — aam-platform, test
#   realms, ...), same as the exact_username migration next to it.
#
# What it sets (mirrors realm_config.json — keep the two in sync):
#   eventsEnabled              true
#   eventsExpiration           90 days, so the table stays bounded without a cron job
#   enabledEventTypes          a security-relevant subset, not Keycloak's noisy default set
#   adminEventsEnabled         true   (who changed a realm/user/client)
#   adminEventsDetailsEnabled  false  (the full request payloads are large and
#                                     contain user data we do not need)
#
#   eventsListeners is deliberately NOT touched: it is read from the realm and
#   written back unchanged, so an existing "metrics-listener" / "jboss-logging"
#   entry survives. Overwriting it would silently disable metrics.
#
# Storage impact:
#   Events land in the EVENT_ENTITY / ADMIN_EVENT_ENTITY tables in the Keycloak
#   Postgres, and Keycloak expires them itself once eventsExpiration is set — no
#   external pruning needed. Budget for it in the Keycloak DB volume, not in the
#   instance volumes.
#
# Safe to re-run: it compares the realm's current config against the target and
# skips realms that already match. DRY-RUN by default; pass --apply to write.
#
# Usage:
#   ./migrate-keycloak-event-config.sh                        # dry-run, all realms
#   ./migrate-keycloak-event-config.sh --apply                # write, all realms
#   ./migrate-keycloak-event-config.sh --realm acme           # dry-run, single realm
#   ./migrate-keycloak-event-config.sh --realm acme --apply
#   ./migrate-keycloak-event-config.sh --include-master --apply
#
# Credentials: set KEYCLOAK_HOST / KEYCLOAK_USER / KEYCLOAK_PASSWORD in the
# environment to run ad-hoc; otherwise they are fetched from Bitwarden (BWS),
# same as the other migration scripts (requires BWS_ACCESS_TOKEN).
#
# Requires: bash, curl, jq

set -uo pipefail

baseDirectory="${baseDirectory:-/var/docker}"
[ -f "$baseDirectory/ndb-setup/setup.env" ] && source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"
source "$baseDirectory/ndb-setup/scripts/lib/keycloak.sh"

##############################
# args
##############################

APPLY=false
ONE_REALM=""
INCLUDE_MASTER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)          APPLY=true ;;
    --realm)          ONE_REALM="${2:?--realm needs a value}"; shift ;;
    --include-master) INCLUDE_MASTER=true ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

##############################
# credentials (env override, else BWS like the sibling scripts)
##############################

if [[ -z "${KEYCLOAK_HOST:-}" || -z "${KEYCLOAK_USER:-}" || -z "${KEYCLOAK_PASSWORD:-}" ]]; then
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    echo "ERROR: set KEYCLOAK_HOST/KEYCLOAK_USER/KEYCLOAK_PASSWORD, or BWS_ACCESS_TOKEN for Bitwarden." >&2
    exit 1
  fi
  bws config server-base https://vault.bitwarden.eu
  KEYCLOAK_HOST=$(bws secret -t "$BWS_ACCESS_TOKEN" get "3db87144-76c9-4690-8f59-b22600c8c927" | jq -r .value)
  KEYCLOAK_PASSWORD=$(bws secret -t "$BWS_ACCESS_TOKEN" get "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" | jq -r .value)
  KEYCLOAK_USER=$(bws secret -t "$BWS_ACCESS_TOKEN" get "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" | jq -r .value)
fi

# Retention for stored events, in seconds. Keycloak expires them itself.
EVENTS_EXPIRATION=7776000   # 90 days

# The event types to store. A subset on purpose: Keycloak's default set stores a
# lot of routine traffic, and every event is a row in the Keycloak Postgres.
# Keep in sync with keycloak/realm_config.json.
ENABLED_EVENT_TYPES='[
  "LOGIN", "LOGIN_ERROR",
  "LOGOUT", "LOGOUT_ERROR",
  "CODE_TO_TOKEN", "CODE_TO_TOKEN_ERROR",
  "REFRESH_TOKEN_ERROR",
  "CLIENT_LOGIN", "CLIENT_LOGIN_ERROR",
  "USER_DISABLED_BY_TEMPORARY_LOCKOUT", "USER_DISABLED_BY_PERMANENT_LOCKOUT",
  "UPDATE_CREDENTIAL", "UPDATE_CREDENTIAL_ERROR",
  "REMOVE_CREDENTIAL", "REMOVE_CREDENTIAL_ERROR",
  "RESET_PASSWORD", "RESET_PASSWORD_ERROR",
  "SEND_RESET_PASSWORD", "SEND_RESET_PASSWORD_ERROR",
  "IDENTITY_PROVIDER_LOGIN_ERROR", "IDENTITY_PROVIDER_FIRST_LOGIN_ERROR",
  "REGISTER", "REGISTER_ERROR",
  "IMPERSONATE", "IMPERSONATE_ERROR",
  "DELETE_ACCOUNT", "DELETE_ACCOUNT_ERROR"
]'

##############################
# migrate one realm
##############################

n_total=0; n_skip=0; n_change=0; n_err=0

migrate_realm() {
  local realm="$1"
  n_total=$((n_total+1))

  # fresh token per realm (admin token lifespan can be short across many realms)
  if ! getKeycloakToken; then
    echo "[$realm] ERROR — could not obtain admin token"
    n_err=$((n_err+1)); return
  fi

  local current
  current=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms/$realm/events/config" \
    -H "Authorization: Bearer $token")

  if ! echo "$current" | jq -e 'has("eventsEnabled")' >/dev/null 2>&1; then
    echo "[$realm] ERROR — could not read events config"
    n_err=$((n_err+1)); return
  fi

  # read-modify-write: keep eventsListeners (and anything else) as it is, so an
  # existing metrics-listener entry is not wiped by this migration
  local desired
  desired=$(echo "$current" | jq \
    --argjson types "$ENABLED_EVENT_TYPES" \
    --argjson exp "$EVENTS_EXPIRATION" \
    '.eventsEnabled = true
     | .eventsExpiration = $exp
     | .enabledEventTypes = ($types | sort)
     | .adminEventsEnabled = true
     | .adminEventsDetailsEnabled = false')

  # compare on the fields we manage, with event types order-insensitive
  local before after
  before=$(echo "$current" | jq -S '{eventsEnabled, eventsExpiration, adminEventsEnabled,
                                     adminEventsDetailsEnabled,
                                     enabledEventTypes: (.enabledEventTypes // [] | sort)}')
  after=$(echo "$desired" | jq -S '{eventsEnabled, eventsExpiration, adminEventsEnabled,
                                    adminEventsDetailsEnabled,
                                    enabledEventTypes: (.enabledEventTypes // [] | sort)}')

  if [ "$before" = "$after" ]; then
    echo "[$realm] = already configured, skipping"
    n_skip=$((n_skip+1)); return
  fi

  if [ "$APPLY" = false ]; then
    # summarise rather than diff: the event type list alone is ~30 lines, which
    # would bury the result across a few dozen realms
    echo "[$realm] would change:"
    jq -rn --argjson b "$before" --argjson a "$after" '
      $b | keys[] as $k
      | select(($b[$k] | tostring) != ($a[$k] | tostring))
      | if ($a[$k] | type) == "array"
        then "    \($k): \($b[$k] | length) -> \($a[$k] | length) types"
        else "    \($k): \($b[$k] | tojson) -> \($a[$k] | tojson)"
        end' | sed "s/^/[$realm]/"
    n_change=$((n_change+1)); return
  fi

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "https://$KEYCLOAK_HOST/admin/realms/$realm/events/config" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$desired")

  if [[ "$code" =~ ^2 ]]; then
    echo "[$realm] + event storage enabled"
    n_change=$((n_change+1))
  else
    echo "[$realm] ERROR — PUT events/config returned HTTP $code"
    n_err=$((n_err+1))
  fi
}

##############################
# main
##############################

$APPLY && echo "MODE: APPLY (writing changes)" || echo "MODE: DRY-RUN (no changes; pass --apply to write)"
echo "Keycloak: https://$KEYCLOAK_HOST"
echo "-------------------------------------------------------------"

if [ -n "$ONE_REALM" ]; then
  migrate_realm "$ONE_REALM"
else
  if ! getKeycloakToken; then
    echo "ERROR: could not obtain admin token to list realms." >&2
    exit 1
  fi
  realms=$(curl -s -L "https://$KEYCLOAK_HOST/admin/realms" \
    -H "Authorization: Bearer $token" | jq -r '.[].realm')
  for realm in $realms; do
    if [ "$realm" = "master" ] && [ "$INCLUDE_MASTER" = false ]; then
      continue
    fi
    migrate_realm "$realm"
  done
fi

echo "-------------------------------------------------------------"
echo "realms processed: $n_total | already-ok: $n_skip | changed: $n_change | errors: $n_err"
$APPLY || echo "DRY-RUN: re-run with --apply to write the changes above."
