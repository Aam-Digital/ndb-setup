#!/bin/bash
# The shared --skip-restart flag. Source it at the top level of a script (never inside a function), right
# after lib/init.sh and before the script's own option parsing:
#
#   source "$scriptDir/lib/skip-restart.sh"
#
# Sourced without arguments it sees the script's own "$@", so that one line
#   - sets $skipRestart to true if --skip-restart was passed, in any position, and
#   - removes the flag from "$@", leaving the positional arguments the script expects
#     (`set --` in a sourced file applies to the sourcing script).
#
# Every script sources it, so --skip-restart is accepted everywhere and is never mistaken for a positional
# argument - also in the scripts that have nothing to restart, where it is simply a no-op.
#
# Guard a restart with $skipRestart, or with skipRestartNote, which also tells the caller what to run:
#   skipRestartNote "docker compose up -d" "$path" || (cd "$path" && docker compose up -d)
#
# Not sourced by: for-each-instance.sh, which has to pass --skip-restart on to the script it runs;
# backup.sh, whose restore is a stop/replace/start with nothing to skip (it rejects the flag); and
# collect-credentials.sh / install-dependencies.sh, which do not use lib/ at all and restart nothing.

skipRestart=false
_skipRestartArgs=()
for _skipRestartArg in "$@"; do
  case "$_skipRestartArg" in
    --skip-restart) skipRestart=true ;;
    *) _skipRestartArgs+=("$_skipRestartArg") ;;
  esac
done
set -- "${_skipRestartArgs[@]+"${_skipRestartArgs[@]}"}"
unset _skipRestartArg _skipRestartArgs

# The flag itself, to pass on to a nested script (empty unless it was given):
#   "$scriptDir/create-couchdb.sh" "$path" ${skipRestartArg[@]+"${skipRestartArg[@]}"}
skipRestartArg=()
if [ "$skipRestart" = true ]; then
  skipRestartArg=(--skip-restart)
fi

# Report a restart left to the caller because of --skip-restart. Returns 0 when the restart is to be
# skipped and 1 when it has to run, so it reads as:
#   skipRestartNote "docker compose up -d" "$path" || (cd "$path" && docker compose up -d)
# Args: the command the caller should run instead, the directory to run it in (optional)
skipRestartNote() {
  [ "$skipRestart" = true ] || return 1
  if [ -n "${2:-}" ]; then
    echo "  --skip-restart: not restarting, run '$1' in $2 to apply the change"
  else
    echo "  --skip-restart: not restarting, run '$1' to apply the change"
  fi
  return 0
}
