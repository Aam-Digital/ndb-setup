#!/bin/bash

# Interactive orchestrator that creates an aam-digital instance end to end.
# It gathers the answers and then delegates each step to a standalone script (create-dns-record.sh,
# create-instance.sh, create-keycloak-realm.sh, create-couchdb.sh, create-initial-user.sh, enable-backend.sh,
# enable-sentry.sh). Each of those can also be run on its own — see the header of each file. Only this
# interactive entry point requires Bitwarden (BWS_ACCESS_TOKEN); the individual scripts resolve their
# config from setup.env / the environment and fall back to BWS only when a token is present.
#
# how to use
#
# make sure to install the dependencies: ./install-dependencies.sh
#
# ./interactive-setup.sh <instance> <baseConfig> <locale> <userEmail> <userName> <withReplicationBackend> <withBackend> <createsMonitors> <enableSentry>
# example: ./interactive-setup.sh qm codo de "mail@foo.bar" "Foo Bar" y y y y

##############################
# setup
##############################

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"        # the ndb-setup checkout

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"

# the interactive setup relies on Bitwarden for all credentials
if [[ -z "${BWS_ACCESS_TOKEN}" ]]; then
  echo "BWS_ACCESS_TOKEN is not set. Abort."
  exit 1
fi

startedWithArgs=false
[ -n "$1" ] && startedWithArgs=true

##############################
# organisation name
##############################

if [ -n "$1" ]; then
  org="$1"
else
  echo "What is the name of the organisation?"
  read -r org
fi
# always ensure org is lowercase to avoid problems with keycloak realms being case sensitive
org=$(echo "$org" | tr '[:upper:]' '[:lower:]')

if ! isValidOrgName "$org"; then
  echo "Error: The organisation name must be non-empty and contain only lowercase letters, digits, and hyphens (not starting/ending with a hyphen). Please try another one."
  exit 1
fi
if grep -Fxq "$org" "$scriptDir/blacklist.txt"; then
  echo "Error: The organisation name '$org' is blacklisted. Please try another one."
  exit 1
fi
if [ ${#org} -ge 24 ]; then
  echo "Error: The organisation name must have less than 24 letters. Please try a shorter one."
  exit 1
fi

path="$baseDirectory/$PREFIX$org"
url=$org.$DOMAIN

##############################
# DNS record
##############################

"$scriptDir/create-dns-record.sh" "$org"

##############################
# new-vs-existing instance
##############################

# authoritative check: the instance directory exists once create-instance.sh has run for it, regardless
# of whether its containers currently happen to be running (docker ps would miss stopped instances)
app=0
[ -d "$path" ] && app=1

if [ "$app" != 0 ]; then
  if [ "$startedWithArgs" = true ]; then
    echo "ERROR name already exists"
    exit 1
  fi
  echo "Instance '$org' already exists"
fi

##############################
# gather remaining answers
##############################

if [ "$app" == 0 ]; then
  if [ -n "$2" ]; then
    baseConfig="$2"
  else
    echo "Which basic config do you want to include? (e.g. [default], basic, codo, ...)"
    read -r baseConfig
    [ -n "$baseConfig" ] || baseConfig=default
  fi

  if [ -n "$3" ]; then
    locale="$3"
  else
    echo "Which should be the default language for Keycloak ('en', 'de', ...)?"
    read -r locale
  fi

  if [ -n "$4" ]; then
    userEmail="$4"
  else
    echo "Email address of initial user"
    read -r userEmail
  fi

  if [ -n "$5" ]; then
    userName="$5"
  else
    echo "Name of initial user"
    read -r userName
  fi
fi

# permission backend (replication-backend) — only ask if not already deployed
replicationBackend=$(docker ps | grep -c "$org-database")
withReplicationBackend=n
if [ "$replicationBackend" == 0 ]; then
  if [ -n "$6" ]; then
    withReplicationBackend="$6"
  else
    echo "Do you want to add the permission backend?[y/n]"
    read -r withReplicationBackend
  fi
fi
withPermissions=false
{ [ "$withReplicationBackend" == "y" ] || [ "$withReplicationBackend" == "Y" ]; } && withPermissions=true

# whether the permission backend (replication-backend) is (or will be) active for this instance,
# either freshly enabled above or already deployed for an existing instance
permissionBackendActive=false
{ [ "$withPermissions" = true ] || [ "$replicationBackend" != 0 ]; } && permissionBackendActive=true

##############################
# create a new instance
##############################

if [ "$app" == 0 ]; then
  # each step is a prerequisite for the next, so abort the whole setup if any of them fails
  "$scriptDir/create-instance.sh" "$org" "$baseConfig" || exit 1
  "$scriptDir/create-keycloak-realm.sh" "$org" "$locale" "$baseConfig" || exit 1

  if [ "$withPermissions" = true ]; then
    "$scriptDir/create-couchdb.sh" "$org" --with-permissions || exit 1
  else
    "$scriptDir/create-couchdb.sh" "$org" || exit 1
  fi

  "$scriptDir/create-initial-user.sh" "$org" "$userEmail" "$userName" || exit 1
fi

# switch on the permission backend profile
if [ "$withPermissions" = true ]; then
  setEnv COMPOSE_PROFILES "with-permissions" "$path/.env"
  echo "replication-backend added"
fi

##############################
# aam-backend (query backend)
##############################

aamBackendService=$(docker ps | grep -c "$org-aam-backend-service")
if [ "$aamBackendService" == 0 ]; then
  if [ -n "$7" ]; then
    withAamBackendService="$7"
  else
    echo "Do you want to add aam-backend-services (backend APIs)? [y/n]"
    read -r withAamBackendService
  fi

  if [ "$withAamBackendService" == "y" ] || [ "$withAamBackendService" == "Y" ]; then
    # enable-backend.sh requires the permission backend (replication-backend) and aborts without it;
    # reject the combination here instead of discovering it after create-couchdb.sh/keycloak have already run
    if [ "$permissionBackendActive" != true ]; then
      echo "ERROR: aam-backend-services requires the permission backend (replication-backend), which is not enabled for '$org'. Skipping backend setup — enable the permission backend first, then rerun enable-backend.sh."
    else
      "$scriptDir/enable-backend.sh" "$org" --skip-restart

      # Enabling the backend also enables (push + email) notifications by default. The enable script loads the
      # Firebase credentials from BWS, so this runs non-interactively. --skip-restart is passed because this
      # script restarts the stack once at the very end, after all enable-* scripts have written their config.
      "$scriptDir/enable-feature-notification.sh" "$org" --skip-restart
    fi
  fi
fi

##############################
# uptime monitoring (deprecated)
##############################

if [ "$app" == 0 ] && [ "${UPTIMEROBOT_API_KEY:-}" != "" ] && [ "${UPTIMEROBOT_ALERT_ID:-}" != "" ]; then
  if [ -n "$8" ]; then
    createsMonitors="$8"
  else
    echo "Do you want create UptimeRobot monitoring? (deprecated, answer is ignored) [y/n]"
    read -r createsMonitors
  fi

  if [ "$createsMonitors" == "y" ] || [ "$createsMonitors" == "Y" ]; then
    curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url&friendly_name=Aam - $org App&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    if [ "$withPermissions" = true ]; then
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/api&friendly_name=Aam - $org Backend&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/couchdb/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    else
      curl -d "api_key=$UPTIMEROBOT_API_KEY&url=https://$url/db/_utils/&friendly_name=Aam - $org DB&alert_contacts=$UPTIMEROBOT_ALERT_ID&type=1" -H "Cache-Control: no-cache" -H "Content-Type: application/x-www-form-urlencoded" "https://api.uptimerobot.com/v2/newMonitor" -w "\n"
    fi
  fi
fi

##############################
# Sentry
##############################

if [ "$app" == 0 ]; then
  if [ -n "$9" ]; then
    enableSentry="$9"
  else
    echo "Do you want to enable Sentry logging?[y/n]"
    read -r enableSentry
  fi
  "$scriptDir/enable-sentry.sh" "$org" "$enableSentry"
fi

##############################
# final restart
##############################

# Single restart for the whole instance, after every enable-* script (run with --skip-restart) has written
# its config. `down && up -d` (not just `up -d`) forces recreation so changed env_file/config is picked up.
(cd "$path" && docker compose down && docker compose up -d)

echo "DONE app is now available under https://$url"
