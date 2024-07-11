#!/bin/bash
# shellcheck disable=SC2046
while true; do (cd /var/docker/ndb-setup || exit; ./interactive_setup.sh $(cat deployer/arg-pipe) >> deployer/log.txt 2>&1 ); done
