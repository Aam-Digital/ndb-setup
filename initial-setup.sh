# use with parameters:
#       couchdb_port
#       couchdb_password
if ! [ $# -eq 2 ]; then
        echo "Usage: $0 couchdb_port couchdb_admin_password"
        exit
fi

# Create system databases for couchdb
curl -X PUT -u admin:$2 https://$1/db/_users
curl -X PUT -u admin:$2 https://$1/db/_replicator
curl -X PUT -u admin:$2 https://$1/db/_global_changes

# create app database
curl -X PUT -u admin:$2 https://$1/db/app
curl -X PUT -u admin:$2 https://$1/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'


# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
