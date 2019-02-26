
Docker Image of [Aam Digital / ndb-core](https://github.com/NGO-DB/ndb-core) and usage instructions.



# Using the Docker Image
You can simply copy the [docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/docker-compose.yaml) file and deploy it (`docker-compose up`).

The system works well with the [nginx-proxy](https://github.com/jwilder/nginx-proxy) docker (see our [nginxproxy.docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/nginxproxy.docker-compose.yaml). Simply have the nginx-proxy service running and adapt the VIRTUAL_HOST environment variable of the ndb-server as needed.


## Initial setup
On the first run some configuration has to be created manually.

see [initial-setup.sh](https://github.com/NGO-DB/docker/blob/master/initial-setup.sh)


-----

# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The files to build the image are in the subfolder `docker-image/`. Get an up-to-date version of the built app into `docker-image/dist` and run the `docker build` command. (also see `docker-image/publish.sh`)

The image builds upon a simple nginx webserver and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs to access the CouchDB database from the same domain, avoiding CORS issues.
