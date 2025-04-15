#!/bin/bash

# simple script for importing a backup to an instance

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
backupRoot=$BACKUP_DIR
passphrase=$BACKUP_PASSPHRASE

echo "For which instance do you want to import the backup?"
read -r org

folder=c-$org

echo "The backup of which day to you want to import? (Format YYYYMMDD e.g. 20220101)"
read -r date

cd $backupRoot
echo "$passphrase" | gpg --batch --yes --passphrase-fd 0 -o output -d $date.tar.gz.gpg
mkdir ~/unpacked
tar -xzvf output --directory ~/unpacked

cd /var/docker/$folder
docker compose down
mv couchdb couchdb_tmp
mv ~/unpacked/var/docker/$folder/couchdb ./couchdb
docker compose up -d

#echo "Delete the temporary data?[y/n]"
#read -r delete
#if [ "$delete" == "y" ] || [ "$delete" == "Y" ]; then
#    rm -r couchdb_tmp
#    rm ~/backups/output
#    rm -rf ~/backups/unpacked
#fi

echo "done"