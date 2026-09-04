#!/bin/bash

# Materialise a `lastLogin` user attribute in Keycloak from the stored login events.
#
# Why this and not an event listener:
#   Keycloak has no built-in last-login field, and the obvious fix — a provider that
#   writes the attribute on every LOGIN event — is expensive here. ndb-core
#   initialises Keycloak with `onLoad: "check-sso"`, and Keycloak fires a LOGIN
#   event on every silent SSO check, so "per login" really means per page load and
#   per new tab. Every one of those writes evicts the user from Keycloak's user
#   cache. This job gets the same queryable field by reading the events that are
#   already stored and writing the attribute at most once per user per run.
#
#   It also outlives the event retention window: each run keeps the newest value it
#   has ever seen, so a user who last logged in two years ago still reports that
#   date long after the event itself has expired out of the store.
#
# Where this is meant to run:
#   Designed to be a scheduled job — a Kubernetes CronJob against the in-cluster
#   Keycloak, or plain cron on a compose server. It is therefore SELF-CONTAINED
#   (like collect-credentials.sh): no lib/ sourcing, no setup.env, no instance
#   directories, no Bitwarden. Everything comes from environment variables, so the
#   only thing an image needs is bash, curl and jq.
#
#   It is also STATELESS: it re-scans a lookback window every run and writes only
#   when it finds something newer than the stored value, so there is nothing to
#   persist between runs and no volume to mount. Re-running is free.
#
# Authentication (either, service account preferred):
#   KEYCLOAK_CLIENT_ID / KEYCLOAK_CLIENT_SECRET   service account on the master realm
#   KEYCLOAK_USER / KEYCLOAK_PASSWORD             admin user (password grant)
#
#   Prefer the service account for a scheduled job: it needs only `view-events`,
#   `view-users` and `manage-users`, whereas the admin user can do everything. A
#   long-lived credential sitting in a cluster secret should be the narrow one.
#
# Required environment:
#   KEYCLOAK_HOST         host only, no scheme (e.g. keycloak.internal)
#
# Optional environment:
#   KEYCLOAK_SCHEME       https (default) — set to http for an in-cluster service
#   LOOKBACK_DAYS         how far back to scan, default 90 (match eventsExpiration)
#   ATTRIBUTE_NAME        default lastLogin
#   PAGE_SIZE             events per request, default 500
#
# Usage:
#   ./sync-keycloak-last-login.sh                       # dry-run, all realms
#   ./sync-keycloak-last-login.sh --apply               # write, all realms
#   ./sync-keycloak-last-login.sh --realm acme --apply
#   ./sync-keycloak-last-login.sh --declare-attribute --apply
#   ./sync-keycloak-last-login.sh --include-master --apply
#
#   DRY-RUN IS THE DEFAULT, for consistency with the migrate-*.sh scripts. A
#   CronJob must therefore pass --apply explicitly, or it will report what it
#   would have done forever and change nothing.
#
# The attribute has to be declared:
#   Keycloak 26 defaults `unmanagedAttributePolicy` to disabled, so writing an
#   attribute the User Profile does not declare is silently dropped — the PUT
#   returns 2xx and the value never appears. This script refuses to run against
#   such a realm rather than reporting success it did not achieve. Pass
#   --declare-attribute to add the declaration (admin-view-only, like
#   exact_username); fresh realms already get it from keycloak/realm_config.json.
#
# Requires: bash, curl, jq

set -uo pipefail

##############################
# args
##############################

APPLY=false
ONE_REALM=""
INCLUDE_MASTER=false
DECLARE_ATTR=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)              APPLY=true ;;
    --realm)              ONE_REALM="${2:?--realm needs a value}"; shift ;;
    --include-master)     INCLUDE_MASTER=true ;;
    --declare-attribute)  DECLARE_ATTR=true ;;
    -h|--help)            grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

##############################
# config
##############################

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required but not installed." >&2; exit 1; }
done

: "${KEYCLOAK_HOST:?ERROR: KEYCLOAK_HOST is not set}"
KEYCLOAK_SCHEME="${KEYCLOAK_SCHEME:-https}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-90}"
ATTRIBUTE_NAME="${ATTRIBUTE_NAME:-lastLogin}"
PAGE_SIZE="${PAGE_SIZE:-500}"
BASE="$KEYCLOAK_SCHEME://$KEYCLOAK_HOST"

# yesterday-inclusive start of the window, in the yyyy-MM-dd the events API takes
DATE_FROM=$(date -u -d "-${LOOKBACK_DAYS} days" +%Y-%m-%d 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%d)

##############################
# auth
##############################

token=""
getToken() {
  local raw
  if [[ -n "${KEYCLOAK_CLIENT_ID:-}" && -n "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
    raw=$(curl -s -L "$BASE/realms/master/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode client_id="$KEYCLOAK_CLIENT_ID" \
      --data-urlencode client_secret="$KEYCLOAK_CLIENT_SECRET")
  elif [[ -n "${KEYCLOAK_USER:-}" && -n "${KEYCLOAK_PASSWORD:-}" ]]; then
    raw=$(curl -s -L "$BASE/realms/master/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=password \
      --data-urlencode client_id=admin-cli \
      --data-urlencode username="$KEYCLOAK_USER" \
      --data-urlencode password="$KEYCLOAK_PASSWORD")
  else
    echo "ERROR: set KEYCLOAK_CLIENT_ID/KEYCLOAK_CLIENT_SECRET (preferred) or KEYCLOAK_USER/KEYCLOAK_PASSWORD." >&2
    return 1
  fi
  token=$(echo "$raw" | jq -r '.access_token // empty')
  [ -n "$token" ] || { echo "ERROR: could not obtain a Keycloak token." >&2; return 1; }
}

kc() { curl -s -L -H "Authorization: Bearer $token" "$@"; }

##############################
# per-realm work
##############################

n_realm=0; n_write=0; n_skip=0; n_err=0

# Ensure the User Profile declares the attribute, otherwise every write is dropped
# silently. Returns non-zero when the realm is not usable.
ensureAttributeDeclared() {
  local realm="$1" profile
  profile=$(kc "$BASE/admin/realms/$realm/users/profile")
  if ! echo "$profile" | jq -e '.attributes' >/dev/null 2>&1; then
    echo "[$realm] ERROR — could not read the user profile"
    return 1
  fi
  if echo "$profile" | jq -e --arg n "$ATTRIBUTE_NAME" \
      '.attributes[]?|select(.name==$n)' >/dev/null 2>&1; then
    return 0
  fi

  if [ "$DECLARE_ATTR" = false ]; then
    echo "[$realm] ERROR — '$ATTRIBUTE_NAME' is not declared in the User Profile."
    echo "[$realm]         Keycloak would accept the write and drop the value."
    echo "[$realm]         Re-run with --declare-attribute, or declare it manually."
    return 1
  fi
  if [ "$APPLY" = false ]; then
    echo "[$realm] would declare '$ATTRIBUTE_NAME' in the User Profile (dry-run)"
    return 0
  fi

  # admin may view, nobody may edit: this value is derived, never user-supplied
  local new code
  new=$(echo "$profile" | jq --arg n "$ATTRIBUTE_NAME" \
    '.attributes += [{name: $n, displayName: "Last login",
                      permissions: {view: ["admin"], edit: []},
                      multivalued: false}]')
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "$BASE/admin/realms/$realm/users/profile" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$new")
  if [[ "$code" =~ ^2 ]]; then
    echo "[$realm] + declared '$ATTRIBUTE_NAME' in the User Profile"
    return 0
  fi
  echo "[$realm] ERROR — declaring '$ATTRIBUTE_NAME' returned HTTP $code"
  return 1
}

# Newest LOGIN per user over the window, as "<userId> <epochMillis>" lines.
# Paged: `max` is bounded server-side, and a truncated scan would report an
# active user as dormant.
collectLastLogins() {
  local realm="$1" first=0 page
  : > "$TMP/events"
  while :; do
    page=$(kc --get "$BASE/admin/realms/$realm/events" \
      --data-urlencode "type=LOGIN" \
      --data-urlencode "dateFrom=$DATE_FROM" \
      --data-urlencode "direction=desc" \
      --data-urlencode "first=$first" \
      --data-urlencode "max=$PAGE_SIZE")
    if ! echo "$page" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "[$realm] ERROR — could not read events (check the view-events role)"
      return 1
    fi
    local n
    n=$(echo "$page" | jq 'length')
    [ "$n" -eq 0 ] && break
    echo "$page" | jq -r '.[] | select(.userId != null) | "\(.userId) \(.time)"' >> "$TMP/events"
    [ "$n" -lt "$PAGE_SIZE" ] && break
    first=$((first + PAGE_SIZE))
  done
  # keep the max per user. awk rather than `sort -u -k1,1`, which would pick an
  # arbitrary row per user: sort is not stable unless asked, so "first wins"
  # after a descending sort is not something it guarantees.
  sort -k1,1 -k2,2nr "$TMP/events" | awk '!seen[$1]++' > "$TMP/latest"
}

syncRealm() {
  local realm="$1"
  n_realm=$((n_realm+1))

  getToken || { n_err=$((n_err+1)); return; }   # fresh token per realm: admin tokens are short
  ensureAttributeDeclared "$realm" || { n_err=$((n_err+1)); return; }
  collectLastLogins "$realm" || { n_err=$((n_err+1)); return; }

  local count
  count=$(wc -l < "$TMP/latest" | tr -d ' ')
  echo "[$realm] $count user(s) with a login in the last $LOOKBACK_DAYS day(s)"

  local userId epochMs iso user current
  while read -r userId epochMs; do
    [ -n "$userId" ] || continue
    iso=$(date -u -d "@$((epochMs / 1000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$((epochMs / 1000))" +%Y-%m-%dT%H:%M:%SZ)

    user=$(kc "$BASE/admin/realms/$realm/users/$userId")
    if ! echo "$user" | jq -e '.id' >/dev/null 2>&1; then
      echo "[$realm]   ! $userId — no such user any more, skipping"
      n_skip=$((n_skip+1)); continue
    fi

    # ISO-8601 UTC sorts lexicographically, so a plain string compare is a date
    # compare — and it keeps the value readable in the admin console.
    current=$(echo "$user" | jq -r --arg n "$ATTRIBUTE_NAME" '.attributes[$n][0] // ""')
    if [[ -n "$current" && ! "$iso" > "$current" ]]; then
      n_skip=$((n_skip+1)); continue
    fi

    if [ "$APPLY" = false ]; then
      echo "[$realm]   would set $ATTRIBUTE_NAME=$iso for $userId (was '${current:-unset}')"
      n_write=$((n_write+1)); continue
    fi

    # Read-modify-write. A bare PUT with only this attribute REPLACES the whole
    # map and would drop exact_username, unlinking the account from its profile.
    local body code
    body=$(echo "$user" | jq --arg n "$ATTRIBUTE_NAME" --arg v "$iso" \
      '{attributes: ((.attributes // {}) + {($n): [$v]})}')
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
      "$BASE/admin/realms/$realm/users/$userId" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$body")
    if [[ "$code" =~ ^2 ]]; then
      n_write=$((n_write+1))
    else
      echo "[$realm]   ERROR — PUT user $userId returned HTTP $code"
      n_err=$((n_err+1))
    fi
  done < "$TMP/latest"
}

##############################
# main
##############################

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

$APPLY && echo "MODE: APPLY (writing changes)" || echo "MODE: DRY-RUN (no changes; pass --apply to write)"
echo "Keycloak: $BASE"
echo "Window:   $DATE_FROM .. now (${LOOKBACK_DAYS}d), attribute '$ATTRIBUTE_NAME'"
echo "-------------------------------------------------------------"

if [ -n "$ONE_REALM" ]; then
  syncRealm "$ONE_REALM"
else
  getToken || exit 1
  realms=$(kc "$BASE/admin/realms" | jq -r '.[].realm')
  [ -n "$realms" ] || { echo "ERROR: could not list realms." >&2; exit 1; }
  for realm in $realms; do
    if [ "$realm" = "master" ] && [ "$INCLUDE_MASTER" = false ]; then
      continue
    fi
    syncRealm "$realm"
  done
fi

echo "-------------------------------------------------------------"
echo "realms: $n_realm | written: $n_write | already-current: $n_skip | errors: $n_err"
$APPLY || echo "DRY-RUN: re-run with --apply to write the changes above."
# non-zero on failure so a CronJob surfaces it instead of reporting success
[ "$n_err" -eq 0 ]
