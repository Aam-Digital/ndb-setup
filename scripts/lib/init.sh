#!/bin/bash
# Setup shared by every script. Source it first:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/init.sh"
#
# Sets:
#   scriptDir      this scripts/ folder
#   ndbSetupDir    the ndb-setup checkout
#   baseDirectory  its parent folder, where the instances ($PREFIX* folders) live
# and loads setup.env plus the helpers of lib/common.sh and lib/secrets.sh. Other lib files (couchdb.sh,
# keycloak.sh) are sourced by the scripts that need them.

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"
baseDirectory="$(cd "$ndbSetupDir/.." && pwd)"

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"
