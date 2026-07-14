#!/bin/bash

# Create the DNS CNAME record for an instance (Hetzner DNS).
# Idempotent: if a CNAME with the instance name already exists in the zone, it is left untouched.
#
# Usage:
#   ./create-dns-record.sh <instance>
#
# Config (via setup.env / environment, or Bitwarden Secrets Manager when BWS_ACCESS_TOKEN is set):
#   DNS_HETZNER_API_TOKEN, DNS_HETZNER_ZONE_ID_APP   (BWS-backed)
#   DNS_SERVER_NAME                                  (setup.env / environment)

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
requireConfig DNS_HETZNER_ZONE_ID_APP
requireConfig DNS_SERVER_NAME

##############################
# script
##############################

# idempotency: skip if a CNAME with this name already exists in the zone
existingId=$(curl -s "https://dns.hetzner.com/api/v1/records?zone_id=$DNS_HETZNER_ZONE_ID_APP" \
  -H "Auth-API-Token: $DNS_HETZNER_API_TOKEN" \
  | jq -r --arg n "$org" '.records[]? | select(.type=="CNAME" and .name==$n) | .id' | head -n1)

if [ -n "$existingId" ]; then
  echo "DNS record for '$org' already exists (id $existingId), skipping."
  exit 0
fi

echo "Creating DNS CNAME record for '$org'..."
body=$(jq -n \
  --arg value "$DNS_SERVER_NAME.aam-digital.net." \
  --arg name "$org" \
  --arg zone_id "$DNS_HETZNER_ZONE_ID_APP" \
  '{value: $value, type: "CNAME", name: $name, zone_id: $zone_id}')

status=$(curl -s -o /dev/null -w "%{http_code}" -X "POST" "https://dns.hetzner.com/api/v1/records" \
     -H 'Content-Type: application/json' \
     -H "Auth-API-Token: $DNS_HETZNER_API_TOKEN" \
     -d "$body")

if [ "$status" != "200" ] && [ "$status" != "201" ]; then
  echo "ERROR: failed to create DNS record for '$org' (HTTP $status)." >&2
  exit 1
fi
echo "DNS record created."
