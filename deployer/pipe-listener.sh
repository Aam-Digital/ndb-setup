#!/bin/bash
# shellcheck disable=SC2086
while true; do (cd /var/docker/ndb-setup/scripts || exit; while read -r line; do ./interactive-setup.sh ${line}; done<deployer/arg-pipe ); done
