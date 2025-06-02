#!/bin/bash

# simple script for importing a backup to an instance

baseDirectory="/var/docker"
source "$baseDirectory/ndb-setup/setup.env"
backupRoot=$BACKUP_DIR
passphrase=$BACKUP_PASSPHRASE

echo "The backup of which day to you want to import? (Format YYYYMMDD e.g. 20220101)"
read -r date

cd "$backupRoot"

echo "decrypting backup ..."
echo "$passphrase" | gpg --batch --yes --passphrase-fd 0 -o output -d $date.tar.gz.gpg

unpackDir="$baseDirectory/_backup_$date"
echo "unpacking backup to $unpackDir ..."
mkdir "$unpackDir"
tar -xzf output --directory "$unpackDir"
rm output

read -p "Do you want to restore a specific system? [y/n] " choice
if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
    echo "Archive unpacked to $unpackDir. Stopping here."
    exit 0
fi

echo "For which instance do you want to import the backup?"
read -r org
folder=c-$org
cd /var/docker/$folder
docker compose down
mv couchdb couchdb_tmp
mv "$unpackDir/var/docker/$folder/couchdb" ./couchdb
docker compose up -d
echo "backup restored for $folder and instance has been restarted"


#echo "Delete the temporary data? [y/n]"
#read -r delete
#if [ "$delete" == "y" ] || [ "$delete" == "Y" ]; then
#    rm -r couchdb_tmp
#    rm ~/backups/output
#    rm -rf ~/backups/unpacked
#fi

echo "done"