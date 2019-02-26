
Docker Image of [Aam Digital / ndb-core](https://github.com/NGO-DB/ndb-core) and usage instructions.



# Using the Docker Image
You can simply copy the [docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/docker-compose.yaml) file and deploy it (`docker-compose up`).


## Initial setup
On the first run some configuration has to be created manually.

see [initial-setup.sh](https://github.com/NGO-DB/docker/blob/master/initial-setup.sh)


## Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/jwilder/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

see our [nginxproxy.docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/nginxproxy.docker-compose.yaml) for a sample service that can be copied. Then simply adapt the VIRTUAL_HOST environment variable of the ndb-server docker-compose.yaml as needed and uncomment the lines relating to the `nginx-proxy_default` network.


-----

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The files to build the image are in the subfolder `docker-image/`. Get an up-to-date version of the built app into `docker-image/dist` and run the `docker build` command. (also see `docker-image/publish.sh`)

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
