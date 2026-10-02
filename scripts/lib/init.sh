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
#
# -h / --help in any position (before a "--") calls the script's usage(), defined at its top, with exit code
# 0. That happens before setup.env is loaded, so the help also works without one. A script that parses
# -h / --help itself (for-each-instance.sh, whose arguments after the command belong to the command) sets
# ownHelpFlag=true before sourcing this file.

if [ "${ownHelpFlag:-}" != true ] && declare -F usage >/dev/null; then
  for _helpArg in "$@"; do
    case "$_helpArg" in
      --) break ;;
      -h | --help) usage 0 ;;
    esac
  done
  unset _helpArg
fi

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ndbSetupDir="$(cd "$scriptDir/.." && pwd)"
baseDirectory="$(cd "$ndbSetupDir/.." && pwd)"

source "$ndbSetupDir/setup.env"
source "$scriptDir/lib/common.sh"
source "$scriptDir/lib/secrets.sh"
