# use with parameters:
#       couchdb_port
#       couchdb_password
if ! [ $# -ge 2 ]; then
        echo "Usage: $0 aam_url couchdb_admin_password"
        echo "Example with backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD> <DATABASE_PASSWORD>"
        echo "Example without backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD>"
        exit
fi

# Create system databases for couchdb
curl -X PUT -u admin:$2 $1/db/_users
curl -X PUT -u admin:$2 $1/db/_replicator
curl -X PUT -u admin:$2 $1/db/_global_changes

# create app database
curl -X PUT -u admin:$2 $1/db/app

if  [ $# -eq 2 ]; then
        curl -X PUT -u admin:$2 $1/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
        echo "No password provided for permission backend. No replicator user is set up"
        exit
fi
# setup replicator user
curl -X PUT -u admin:$2 $1/db/_users/org.couchdb.user:replicator -d '{"name": "replicator", "password": "'$3'", "roles": [], "type": "user"}'
curl -X PUT -u admin:$2 $1/db/_users/_security -d '{"admins": { "names": ["replicator"], "roles": ["_admin"] }, "members": { "names": [], "roles": ["_admin"] } }'
curl -X PUT -u admin:$2 $1/db/app/_security -d '{"admins": { "names": [], "roles": ["_admin"] }, "members": { "names": ["replicator"], "roles": ["_admin"] } }'

# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
