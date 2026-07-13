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
# Requires: jq, and (for the BWS path) the `bws` CLI + BWS_ACCESS_TOKEN.

# Map a config key to its Bitwarden Secrets Manager secret UUID.
# A case statement (rather than an associative array) keeps this working on bash 3.2 (macOS).
_bwsSecretId() {
  case "$1" in
    DNS_HETZNER_API_TOKEN)          echo "1be6f4e3-2abf-4d53-8e13-b22600ace76e" ;;
    DNS_HETZNER_ZONE_ID_APP)        echo "f0507ee8-6a72-4dca-b1f1-b22800844dac" ;;
    KEYCLOAK_HOST)                  echo "3db87144-76c9-4690-8f59-b22600c8c927" ;;
    KEYCLOAK_PASSWORD)              echo "c5f42f09-b1c8-43a8-ae75-b22600c8f2e5" ;;
    KEYCLOAK_USER)                  echo "fbe4ba07-538d-49e2-92dd-b22600c8d9d2" ;;
    SENTRY_DSN_APP)                 echo "b1b07d2d-05de-41c6-8ac6-b22700766968" ;;
    SENTRY_DSN_REPLICATION_BACKEND) echo "359ea1c0-798e-4e17-ae44-b2e20153051d" ;;
    SENTRY_DSN_BACKEND)             echo "a858a580-9643-4330-8667-b2270073d7a6" ;;
    SENTRY_AUTH_TOKEN)              echo "b9a3e1eb-3925-4ed6-93f4-b2270073c82c" ;;
    SMTP_SERVER)                    echo "55bf05ce-03ed-40fb-8320-b2ce00cf6760" ;;
    SMTP_PASSWORD)                  echo "ec5d7f0a-62e3-46d7-a7c7-b2ce00cf8abc" ;;
    RENDER_API_CLIENT_ID_DEV)       echo "b53d7a1d-220e-4e07-b1f9-b22700711f79" ;;
    RENDER_API_CLIENT_SECRET_DEV)   echo "83a8e38b-fc22-461f-91a0-b22700712b62" ;;
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
# and the key has a known secret UUID). Prints the value to stdout; returns non-zero if unresolved.
getConfig() {
  local key="$1"

  # 1) already provided via environment / setup.env
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi

  # 2) Bitwarden Secrets Manager (optional)
  local uuid
  if [ -n "${BWS_ACCESS_TOKEN:-}" ] && uuid=$(_bwsSecretId "$key"); then
    _ensureBwsServer
    local value
    value=$(bws secret -t "$BWS_ACCESS_TOKEN" get "$uuid" 2>/dev/null | jq -r '.value // empty')
    if [ -n "$value" ]; then
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
  if _bwsSecretId "$key" >/dev/null; then
    echo "  Provide it in setup.env / the environment, or set BWS_ACCESS_TOKEN to load it from Bitwarden." >&2
  else
    echo "  Provide it in setup.env or the environment." >&2
  fi
  [ -n "$hint" ] && echo "  $hint" >&2
  exit 1
}
