#!/bin/bash
# shellcheck disable=SC2046
while true; do (cd /var/docker/setup; ./interactive_setup.sh $(cat deployer/arg-pipe)); done
