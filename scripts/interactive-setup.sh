#!/bin/bash
usage() {
  cat <<'EOF'
Create a new instance end to end, running the individual scripts: create-dns-record.sh, create-instance.sh,
create-keycloak-realm.sh, create-couchdb.sh, create-initial-user.sh, enable-backend.sh (optional) and
enable-sentry.sh. The instance is restarted once at the end.

Usage:
  ./interactive-setup.sh [name] [baseConfig] [locale] [userEmail] [userName] [withReplicationBackend]
                         [withBackend] [unused] [enableSentry] [--skip-restart]

Asks for every argument that is not given (y/n for the with*/enable* ones).
Example: ./interactive-setup.sh acme basic de "admin@example.com" "Admin Name" y y y y

Requires BWS_ACCESS_TOKEN (Bitwarden), unlike the individual scripts. Install the bws CLI with
./install-dependencies.sh.
EOF
  exit "${1:-1}"
}

# The 8th argument used to answer an UptimeRobot monitoring prompt and is ignored since that step was removed.
# The slot is kept rather than closed because the argument line is assembled by the external deployer-backend
# service (see deployer/), whose code is not in this repo - so callers may still be passing <enableSentry> in
# position 9.

##############################
# setup
##############################

source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
# --skip-restart (and $skipRestart), stripped from "$@" so the positional args stay intact
source "$scriptDir/lib/skip-restart.sh"

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
    "$scriptDir/create-couchdb.sh" "$org" --with-permissions ${skipRestartArg[@]+"${skipRestartArg[@]}"} || exit 1
  else
    "$scriptDir/create-couchdb.sh" "$org" ${skipRestartArg[@]+"${skipRestartArg[@]}"} || exit 1
  fi

  "$scriptDir/create-initial-user.sh" "$org" "$userEmail" "$userName" || exit 1
fi

# switch on the permission backend profile
if [ "$withPermissions" = true ]; then
  setEnv COMPOSE_PROFILES "with-permissions" "$path/.env"
  # the app container's /db now needs to reach replication-backend instead of CouchDB directly
  upsertEnv DB_ENTRYPOINT_URL "http://${org}-replication-backend:5984" "$path/.env"
  # an existing database-only instance still has the permissive "user_app" _security and CouchDB's JWT auth
  if [ "$app" != 0 ]; then
    "$scriptDir/create-couchdb.sh" "$org" --with-permissions ${skipRestartArg[@]+"${skipRestartArg[@]}"} || exit 1
  fi
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
      "$scriptDir/enable-notifications.sh" "$org" --skip-restart
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
if ! skipRestartNote "docker compose down && docker compose up -d" "$path"; then
  (cd "$path" && docker compose down && docker compose up -d)
fi

if [ "$skipRestart" = true ]; then
  echo "DONE setting up '$org' - it is available under https://$url once you have restarted it."
else
  echo "DONE app is now available under https://$url"
fi
