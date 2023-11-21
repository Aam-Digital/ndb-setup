# Deployer backend

Automatically deploy new instances on the server.

## Setup

1. Create the `arg-pipe`
    > mkfifo arg-pipe
2. Assign all required variables in `.env`
3. Start the app
    > docker compose up -d
4. Run the script which listens to new deployment instructions
   > ./pipe-listener.sh
5. Visit `<DEPLOYER_URL>/api` in you browser and send requests to the `/deploy` endpoint

## Listen infinitely

To start the script without a shell run
   > nohup ./pipe-listener.sh &

To later stop this process again run
   > ps auxwww | grep pipe-listener

And kill all the processes using the PID number in the second column
   > kill <PID>

To also have it running after server restarts use crontab
   > crontab -e

And add `@reboot /var/docker/setup/deployer/pipe-listener.sh`