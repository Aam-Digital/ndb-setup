# use with parameters:
#       couchdb_port
#       couchdb_password
if ! [ $# -ge 2 ]; then
        echo "Usage: $0 aam_url couchdb_admin_password"
        echo "Example with backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD> <DATABASE_PASSWORD>"
        echo "Example without backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD>"
        exit
fi

if  [ $# -eq 2 ]; then
  # Create system databases for couchdb
  curl -X PUT -u admin:$2 $1/db/_users
  curl -X PUT -u admin:$2 $1/db/_replicator
  curl -X PUT -u admin:$2 $1/db/_global_changes
  curl -X PUT -u admin:$2 $1/db/app

  # no backend defined, allowing 'user_app' to access 'app' database and modify their own user object
  curl -X PUT -u admin:$2 $1/db/_users/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  curl -X PUT -u admin:$2 $1/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
  echo "No password provided for permission backend. No replicator user is set up"
  exit
fi

# Create system databases for couchdb behind proxy
curl -X PUT -u admin:$2 $1/db/couchdb/_users
curl -X PUT -u admin:$2 $1/db/couchdb/_replicator
curl -X PUT -u admin:$2 $1/db/couchdb/_global_changes
curl -X PUT -u admin:$2 $1/db/couchdb/app
# setup replicator user and give it access to 'app' and '_users' database
curl -X PUT -u admin:$2 $1/db/couchdb/_users/org.couchdb.user:replicator -d '{"name": "replicator", "password": "'$3'", "roles": [], "type": "user"}'
curl -X PUT -u admin:$2 $1/db/couchdb/_users/_security -d '{"admins": { "names": ["replicator"], "roles": ["_admin"] }, "members": { "names": [], "roles": [] } }'
curl -X PUT -u admin:$2 $1/db/couchdb/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": ["replicator"], "roles": ["_admin"] } }'

# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
