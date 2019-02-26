# Copy asset folder if empty
ASSETS_DIR="./assets"
if ! [ "$(ls -A $ASSETS_DIR)" ]; then
    docker cp ndb-server:/usr/share/nginx/html/assets.original $ASSETS_DIR
fi
/usr/share/nginx/html/assets.original

# Create system databases for couchdb
#curl -X PUT http://127.0.0.1:5984/_users
#curl -X PUT http://127.0.0.1:5984/_replicator
#curl -X PUT http://127.0.0.1:5984/_global_changes

# create app database
#curl -X PUT http://127.0.0.1:5984/app

# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
