#!/bin/bash
# System backups: encrypted archives of the whole base directory (all instances, and this checkout) in
# BACKUP_DIR, one per day ("YYYYMMDD.tar.gz.gpg"), encrypted with BACKUP_PASSPHRASE (both from setup.env).
#
# Usage:
#   ./backup.sh [create] [--keep <n>]      create today's backup, keep the newest <n> (default 14); for cron
#   ./backup.sh list                       list the available backups
#   ./backup.sh restore [<date> [<instance>]]
#       unpack the backup of <date> (YYYYMMDD) next to the instances, and if an instance is given (or chosen
#       when asked), replace that instance's CouchDB data with the backed-up one and restart it. Only the
#       CouchDB data is restored, not its .env or config. The replaced data is kept next to it.
#
# Can be run from any directory.

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseDirectory="$(cd "$scriptDir/../.." && pwd)"   # parent of the ndb-setup checkout (instances live here)
source "$baseDirectory/ndb-setup/setup.env"
source "$baseDirectory/ndb-setup/scripts/lib/common.sh"

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

backupRoot="${BACKUP_DIR:-}"
passphrase="${BACKUP_PASSPHRASE:-}"
if [ -z "$backupRoot" ] || [ -z "$passphrase" ]; then
  echo "ERROR: BACKUP_DIR and BACKUP_PASSPHRASE must be set in setup.env."
  exit 1
fi

##############################
# create
##############################

createBackup() {
  local keep=14
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep) keep="${2:-}"; [[ "$keep" =~ ^[1-9][0-9]*$ ]] || usage; shift 2 ;;
      *) usage ;;
    esac
  done

  mkdir -p "$backupRoot" || exit 1
  local target
  target="$backupRoot/$(date +%Y%m%d)"
  echo "Creating backup $target.tar.gz.gpg ($(date '+%Y-%m-%d %H:%M:%S')) ..."

  # tar exits with 1 if files changed while being read (live databases), which still is a usable archive
  tar zcf "$target.tar.gz" "$baseDirectory"
  if [ "$?" -gt 1 ]; then
    echo "ERROR: creating the archive failed."
    rm -f "$target.tar.gz"
    exit 1
  fi
  # never leave the unencrypted archive behind
  if ! gpg -c --batch --yes --passphrase "$passphrase" "$target.tar.gz"; then
    echo "ERROR: encrypting the archive failed."
    rm -f "$target.tar.gz"
    exit 1
  fi
  rm -f "$target.tar.gz"
  chown root:root "$target.tar.gz.gpg" 2>/dev/null

  # delete older backups, keeping the newest $keep
  local old
  old=$(ls -1t "$backupRoot"/*.tar.gz.gpg 2>/dev/null | tail -n +"$((keep + 1))")
  if [ -n "$old" ]; then
    echo "Removing $(echo "$old" | wc -l) old backup(s) ..."
    echo "$old" | while IFS= read -r f; do rm -f -- "$f"; done
  fi
  echo "Backup created."
}

##############################
# list
##############################

listBackups() {
  local f found=false
  for f in "$backupRoot"/*.tar.gz.gpg; do
    [ -f "$f" ] || continue
    found=true
    printf '%s\t%s\n' "$(basename "$f" .tar.gz.gpg)" "$(du -h "$f" | cut -f1)"
  done
  [ "$found" = true ] || echo "No backups in $backupRoot."
}

##############################
# restore
##############################

restoreBackup() {
  local date="${1:-}" instanceArg="${2:-}"
  if [ -z "$date" ]; then
    echo "The backup of which day do you want to import? (Format YYYYMMDD e.g. 20220101)"
    read -r date
  fi
  local archive="$backupRoot/$date.tar.gz.gpg"
  if [ ! -f "$archive" ]; then
    echo "ERROR: no backup $archive. Available: $(listBackups | cut -f1 | tr '\n' ' ')"
    exit 1
  fi

  local unpackDir="$baseDirectory/_backup_$date"
  local decrypted="$backupRoot/.restore-$date.tar.gz"
  echo "decrypting backup ..."
  if ! echo "$passphrase" | gpg --batch --yes --passphrase-fd 0 -o "$decrypted" -d "$archive"; then
    echo "ERROR: decrypting $archive failed."
    rm -f "$decrypted"
    exit 1
  fi
  echo "unpacking backup to $unpackDir ..."
  mkdir -p "$unpackDir"
  tar -xzf "$decrypted" --directory "$unpackDir"
  local rc=$?
  rm -f "$decrypted"
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: unpacking the backup failed."
    exit 1
  fi

  if [ -z "$instanceArg" ]; then
    read -r -p "Do you want to restore a specific system? [y/n] " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
      echo "Archive unpacked to $unpackDir. Stopping here."
      exit 0
    fi
    echo "For which instance do you want to import the backup?"
    read -r instanceArg
  fi
  resolveInstancePath "$instanceArg" || exit 1
  local folder
  folder=$(basename "$path")

  # tar strips the leading "/" of the archived $baseDirectory, so the unpacked tree is rooted at
  # $baseDirectory without its leading slash (not necessarily "var/docker")
  local backedUpData="$unpackDir/${baseDirectory#/}/$folder/couchdb"
  if [ ! -d "$backedUpData" ]; then
    echo "ERROR: the backup of $date has no CouchDB data for '$folder' ($backedUpData). Nothing changed."
    exit 1
  fi

  local replacedData
  replacedData="couchdb.before-restore-$(date +%Y%m%d%H%M%S)"
  cd "$path" || exit 1
  docker compose down
  mv couchdb "$replacedData"
  mv "$backedUpData" ./couchdb
  docker compose up -d
  echo "Backup of $date restored for $folder, and the instance restarted."
  echo "  The replaced CouchDB data is in $path/$replacedData - delete it once the restore is verified."
  echo "  The unpacked backup is in $unpackDir - delete it when done."
}

##############################
# main
##############################

case "${1:-create}" in
  create) shift || true; createBackup "$@" ;;
  --keep) createBackup "$@" ;;
  list) listBackups ;;
  restore) shift; restoreBackup "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
