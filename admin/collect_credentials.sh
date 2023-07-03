initial=$PWD

# Navigate to folder where AamDigital instances are located (default /var/docker)
cd ${1:-/var/docker} || exit
res="["
for D in *; do
        if [ -d "${D}" ] && [[ $D == ndb-* ]]; then
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
                res=$res$'\n\t{ "name": "'${D#*ndb-}'", "password": "'$pw'" },'
        fi
done
res=${res::-1}  # Remove last comma
res=$res$'\n]'
echo "$res" > "$initial"/credentials.json

