# Copy asset folder if empty
if ! [ "$(ls -A assets)" ]; then
    docker cp ndb-demo_webserver_1:/usr/share/nginx/html/assets.original ./
    mv assets.original/* assets/
    rmdir assets.original
fi

# Create system databases for couchdb
#curl -X PUT http://127.0.0.1:5984/_users
#curl -X PUT http://127.0.0.1:5984/_replicator
#curl -X PUT http://127.0.0.1:5984/_global_changes

# create app database
#curl -X PUT http://127.0.0.1:5984/app

# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
