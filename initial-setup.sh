# use with parameters:
#       couchdb_port
#       couchdb_password
if ! [ $# -ge 2 ]; then
        echo "Usage: $0 aam_url couchdb_admin_password"
        echo "Example with backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD> true"
        echo "Example without backend: $0 https://demo.aam-digital.com <COUCHDB_PASSWORD>"
        exit
fi

# Create system databases for couchdb
curl -X PUT -u admin:$2 $1/db/_users
curl -X PUT -u admin:$2 $1/db/_replicator
curl -X PUT -u admin:$2 $1/db/_global_changes
curl -X PUT -u admin:$2 $1/db/app

if [ "$3" == "true" ]; then
  # No need to update security documents
  exit
fi

# allowing 'user_app' to access 'app' database and modify their own user object
curl -X PUT -u admin:$2 $1/db/_users/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
curl -X PUT -u admin:$2 $1/db/app/_security -d '{"admins": { "names": [], "roles": [] }, "members": { "names": [], "roles": ["user_app"] } }'
echo "'user_app' has access to 'app' database"
exit

# add users
#js ./ndb-admin/add-user.js admin:ADMIN_PASSWORD app USER USER_PASSWORD
