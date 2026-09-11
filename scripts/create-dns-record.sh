#!/bin/bash

# Create the DNS CNAME record for an instance (Hetzner DNS).
# Idempotent: if a CNAME with the instance name already exists in the zone, it is left untouched.
#
# Usage:
#   ./create-dns-record.sh <instance>
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   DNS_HETZNER_API_TOKEN   (BWS-backed) A Hetzner Cloud API token (console.hetzner.com ->
#                           Security -> API Tokens) for whichever Project holds DNS_SERVER_DOMAIN's
#                           zone — tokens are scoped to one Project, so the wrong one looks like "no
#                           such zone", not "wrong token". Hetzner shut the old DNS Console
#                           (dns.hetzner.com) and its API down in May 2026; a token created there
#                           does not work here. There is no separate zone id to configure — the
#                           zone is looked up by DNS_SERVER_DOMAIN's own name (see below), so it
#                           doubles as the query and can't go stale the way a hardcoded id could.
#   DNS_SERVER_NAME                                  (setup.env / environment)
#   DNS_SERVER_DOMAIN                                (setup.env / environment, optional, defaults to aam-digital.net)

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"

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
