# Admin backend

DO NOT DEPLOY PUBLICLY.
This service has access to all DBs and should only be accessible through an SSH Tunnel.

## Deploy on server

1. Set the variables in `.env`
2. Run `./extract_credentials.sh <FOLDER>` where `folder` is the location where the AamDigital instances are located (default `/var/docker`)
3. Run `docker-compose.up -d`

## Connect via SSH tunnel

1. Run `ssh -N -L 3000:127.0.0.1:3000 user@server`
2. Visit `localhost:3000/api` in the browser
3. Stop with `ctrl + c`
