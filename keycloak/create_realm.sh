if ! [ $# -ge 3 ]; then
        echo "Usage: $0 container-ID admin-password name"
        echo "Example with backend: $0 <CONTAINER_ID> <KEYCLOAK_ADMIN_PASSWORD> my_realm"
        exit
fi

# Copy client config file to docker
docker cp ./client_config.json "$1":client_config.json
docker exec -it "$1" /bin/sh

# Commands inside docker image
export PATH=$PATH:/opt/keycloak/bin
# Login
kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$2"
# Create realm
kcadm.sh create realms -s realm="$3" -s enabled=true -o
# Set aam theme
kcadm.sh update realms/"$3" -s loginTheme=aam-theme
# Create client from config file and store ID
CID=$(kcadm.sh create clients -r "$3" -f /client_config.json -i)
# Create default `user_app` role
kcadm.sh create clients/"$CID"/roles -r $3 -s name=user_app -s 'description=Regular user with DB access'
