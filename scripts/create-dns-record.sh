#!/bin/bash
usage() {
  cat <<'EOF'
Create the DNS CNAME record <name>.DNS_SERVER_DOMAIN -> DNS_SERVER_NAME.DNS_SERVER_DOMAIN (Hetzner DNS).
An existing CNAME of that name is left untouched.

Usage:
  ./create-dns-record.sh <name> [--skip-restart]

Config (setup.env / environment, or Bitwarden when BWS_ACCESS_TOKEN is set):
  DNS_HETZNER_API_TOKEN  Hetzner Cloud API token (console.hetzner.com -> Security -> API Tokens) of the
                         Project that holds the DNS_SERVER_DOMAIN zone. Tokens are scoped to one Project, so
                         a token of another one shows up as "no such zone". Tokens of the old DNS Console
                         (dns.hetzner.com, shut down in May 2026) don't work.
  DNS_SERVER_NAME        the server the record points to
  DNS_SERVER_DOMAIN      the zone (optional, default aam-digital.net)
EOF
  exit "${1:-1}"
}

# There is no zone id to configure: the zone is looked up by DNS_SERVER_DOMAIN's name, so it can't go stale
# the way a hardcoded id could.

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart is accepted (and ignored: this script changes no running service), stripped from
# "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

##############################
# input
##############################

if [ -n "$1" ]; then
  org="$1"
else
  echo "What is the name of the organisation?"
  read -r org
fi
# keycloak realms are case sensitive elsewhere, so keep the name lowercase everywhere
org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

requireConfig DNS_HETZNER_API_TOKEN
requireConfig DNS_SERVER_NAME
DNS_SERVER_DOMAIN="${DNS_SERVER_DOMAIN:-aam-digital.net}"

##############################
# script
##############################

zoneId=$(curl -s --fail-with-body "https://api.hetzner.cloud/v1/zones?name=$DNS_SERVER_DOMAIN" \
  -H "Authorization: Bearer $DNS_HETZNER_API_TOKEN" | jq -r '.zones[0].id // empty')
if [ -z "$zoneId" ]; then
  echo "ERROR: no Hetzner zone named '$DNS_SERVER_DOMAIN' visible to DNS_HETZNER_API_TOKEN (it is" >&2
  echo "  scoped to one Hetzner Cloud Project — check it was created in the one that holds this zone)." >&2
  exit 1
fi

# idempotency: skip if a CNAME with this name already exists in the zone
existingId=$(curl -s "https://api.hetzner.cloud/v1/zones/$zoneId/rrsets?name=$org" \
  -H "Authorization: Bearer $DNS_HETZNER_API_TOKEN" \
  | jq -r --arg n "$org" '.rrsets[]? | select(.type=="CNAME" and .name==$n) | .id' | head -n1)

if [ -n "$existingId" ]; then
  echo "DNS record for '$org' already exists (id $existingId), skipping."
  exit 0
fi

echo "Creating DNS CNAME record for '$org'..."
body=$(jq -n \
  --arg value "$DNS_SERVER_NAME.$DNS_SERVER_DOMAIN." \
  --arg name "$org" \
  '{name: $name, type: "CNAME", records: [{value: $value}]}')

status=$(curl -s -o /dev/null -w "%{http_code}" -X "POST" "https://api.hetzner.cloud/v1/zones/$zoneId/rrsets" \
     -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $DNS_HETZNER_API_TOKEN" \
     -d "$body")

if [ "$status" != "200" ] && [ "$status" != "201" ]; then
  echo "ERROR: failed to create DNS record for '$org' (HTTP $status)." >&2
  exit 1
fi
echo "DNS record created."
