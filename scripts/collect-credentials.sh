#!/bin/bash
# Collect CouchDB admin credentials from all Aam Digital instance folders on this server.
#
# Usage: ./collect-credentials.sh [INSTANCES_DIR]
#   INSTANCES_DIR defaults to /var/docker
#
# Output: credentials.json in the current working directory.
#
# Next step: copy the generated credentials.json into your local ndb-core checkout
# and run the admin CLI from there:
#   npm run cli -- migrate list
#   npm run cli -- check

initial=$PWD

# Navigate to folder where AamDigital instances are located (default /var/docker)
cd ${1:-/var/docker} || exit
res="["
for D in *; do
        if [ -d "${D}" ] && [[ $D == c-* ]]; then
                cd "$D" || continue ;
                if [ -f ".env" ]
                then
                        pw=$(cat .env)
                        pw=${pw#*COUCHDB_PASSWORD=}
                else
                        pw=$(cat docker-compose.yml)
                        pw=${pw#*COUCHDB_PASSWORD:[[:space:]]}
                fi
                pw=${pw%%[[:space:]]*}
                cd ..

                if [[ $pw == "version:" ]]; then continue; fi
                res=$res$'\n\t{ "name": "'${D#*c-}'", "password": "'$pw'" },'
        fi
done
res=${res::-1}  # Remove last comma
res=$res$'\n]'
echo "$res" > "$initial"/credentials.json
echo "Written: $initial/credentials.json"
echo "Copy this file into your ndb-core checkout, then run: npm run cli -- check"
