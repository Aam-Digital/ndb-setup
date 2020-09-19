To set up an instance of the Aam Digital app you can use our docker image
following these simple steps:

1. Clone this repository to easily get all the setup files: `git clone https://github.com/Aam-Digital/ndb-setup.git`
2. Edit the `docker-compose.yml` file to set admin passwords and virtual host domain
(or adapt it to expose the app at a port)
3. Create a `config.json` file by copying the [default config](https://github.com/Aam-Digital/ndb-core/blob/master/src/assets/config.default.json)
and adapt it. You should set `"remote_url": "https://example.com/db/"` if your app is available at *example.com*
4. Start the docker containers: `docker-comose up -d`
5. Run `./initial-setup.sh` to create the required databases
6. Run `js add-user.js` to create user accounts



# Deploying under a domain name using nginx-proxy
The system works well with the [nginx-proxy](https://github.com/jwilder/nginx-proxy) docker. This allows to automatically configure things so that the app is reachable under a specific domain name (including automatic setup of SSL certificates through letsencrypt).

see our [nginxproxy.docker-compose.yaml](https://github.com/NGO-DB/docker/blob/master/nginxproxy.docker-compose.yaml) for a sample service that can be copied. Then simply adapt the VIRTUAL_HOST environment variable of the ndb-server docker-compose.yaml as needed and uncomment the lines relating to the `nginx-proxy_default` network.



# Building the Docker Image
*If you just want to use ndb-core through docker, you should not have to build the image yourself. Use the pre-built image on Docker Hub [aamdigital/ndb-server](https://cloud.docker.com/u/aamdigital/repository/docker/aamdigital/ndb-server).*

The Dockerfile to build the image are part of the [ndb-core repository](https://github.com/Aam-Digital/ndb-core).
See the `/docker` subfolder there.

The image builds upon a simple nginx webserver
and modifies the configuration to include a reverse proxy for the `domain.com/db` URLs
to access the CouchDB database from the same domain, avoiding CORS issues.
