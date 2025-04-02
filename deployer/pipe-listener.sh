#!/bin/bash
# shellcheck disable=SC2086
while true; do (cd /var/docker/ndb-setup || exit; while read -r line; do ../scripts/interactive_setup.sh ${line}; done<deployer/arg-pipe ); done
