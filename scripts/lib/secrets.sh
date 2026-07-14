#!/bin/bash
# Config/secret resolution for ndb-setup scripts.
#
# getConfig hides WHERE a value comes from: an already-set environment variable / setup.env value,
# or the Bitwarden Secrets Manager (only consulted when BWS_ACCESS_TOKEN is available).
#
# This lets the standalone scripts run WITHOUT BWS access — just provide the needed values via
# setup.env or the environment — while interactive-setup.sh (and anyone with a token) can keep
# relying on BWS. See setup.example.env for which values are normally BWS-provided.
#
# Requires: jq, and (for the BWS path) the `bws` CLI + BWS_ACCESS_TOKEN, plus common.sh sourced
# first (for getBwsSecretByKey, which looks up secrets by name since bws only supports get-by-id).

# Config keys that are expected to have a same-named secret in Bitwarden Secrets Manager.
# Lookup is by secret name (via common.sh's getBwsSecretByKey), so this is just a whitelist -
# a case statement (rather than an associative array) keeps this working on bash 3.2 (macOS).
_isBwsBackedKey() {
  case "$1" in
    DNS_HETZNER_API_TOKEN | DNS_HETZNER_ZONE_ID_APP | KEYCLOAK_HOST | KEYCLOAK_PASSWORD | \
      KEYCLOAK_USER | SENTRY_DSN_APP | SENTRY_DSN_REPLICATION_BACKEND | SENTRY_DSN_BACKEND | \
      SENTRY_AUTH_TOKEN | SMTP_SERVER | SMTP_PASSWORD | RENDER_API_CLIENT_ID_DEV | \
      RENDER_API_CLIENT_SECRET_DEV | FIREBASE_CONFIG_JSON | FIREBASE_CREDENTIAL_BASE64)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Point the bws CLI at the EU vault, once per process (no-op without a token).
_bwsServerConfigured=false
_ensureBwsServer() {
  if [ "$_bwsServerConfigured" = false ] && [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
    bws config server-base https://vault.bitwarden.eu >/dev/null 2>&1
    _bwsServerConfigured=true
  fi
}

# getConfig KEY
# Resolve a config value. Order: an existing env/setup.env value, then BWS (only if a token is set
# and the key is a known BWS-backed key). Prints the value to stdout; returns non-zero if unresolved.
getConfig() {
  local key="$1"

  # 1) already provided via environment / setup.env
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi

  # 2) Bitwarden Secrets Manager (optional)
  if [ -n "${BWS_ACCESS_TOKEN:-}" ] && _isBwsBackedKey "$key"; then
    _ensureBwsServer
    local value
    if value=$(getBwsSecretByKey "$key"); then
      printf '%s' "$value"
      return 0
    fi
  fi

  return 1
}

# requireConfig KEY [hint]
# Resolve KEY via getConfig into a same-named exported variable, or abort with a helpful message.
# After a successful call the value is available as "$KEY" (e.g. requireConfig KEYCLOAK_HOST -> $KEYCLOAK_HOST).
requireConfig() {
  local key="$1"
  local hint="${2:-}"
  local value
  if value=$(getConfig "$key"); then
    printf -v "$key" '%s' "$value"
    export "$key"
    return 0
  fi
  echo "ERROR: required config '$key' is not set." >&2
  if _isBwsBackedKey "$key"; then
    echo "  Provide it in setup.env / the environment, or set BWS_ACCESS_TOKEN to load it from Bitwarden." >&2
  else
    echo "  Provide it in setup.env or the environment." >&2
  fi
  [ -n "$hint" ] && echo "  $hint" >&2
  exit 1
}
