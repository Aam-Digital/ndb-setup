#!/bin/bash

# simple script to create encrypted backups
# can be scheduled via cron

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
backupRoot=$BACKUP_DIR
passphrase=$BACKUP_PASSPHRASE

targetFile=$backupRoot/`date +%Y%m%d`

tar zcf $targetFile.tar.gz /var/docker
gpg -c --batch --passphrase "$passphrase" $targetFile.tar.gz
chown root:root $targetFile.tar.gz.gpg

rm $targetFile.tar.gz

# delete older backups
keep=14 #set this to how many files want to keep
cd $backupRoot
discard=$(expr $keep - $(ls|wc -l))
if [ $discard -lt 0 ]; then
  ls -Bt|tail $discard|tr '\n' '\0'|xargs -0 printf "%b\0"|xargs -0 rm --
fi