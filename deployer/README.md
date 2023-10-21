# Deployer backend

Automatically deploy new instances on the server.

## Setup

1. Create the `arg-pipe`
    > mkfifo arg-pipe
2. Start the app
    > docker compose up -d
3. On the parent folder pass the arguments to the `interactive_setup.sh` script
   > ./interactive_setup.sh $(cat deployer/arg-pipe)
4. On your local machine run 
    > ssh -N -L 3000:127.0.0.1:3000 user@server
5. Visit `localhost:3000/api` in you browser and send requests to the `/deploy` endpoint
