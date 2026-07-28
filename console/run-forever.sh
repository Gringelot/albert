#!/bin/sh
# Always-on supervisor for the Albert Console server: relaunch on exit.
# Use this when the per-user service is unavailable; it replaces the service's restart policy.
# Five consecutive fast exits (under 10s) mean something structural, like the port already
# being served or a broken install: give up instead of spinning.
set -u

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
fails=0
while :; do
  started=$(date +%s)
  "$HERE/run-hidden.sh" "$@"
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -lt 10 ]; then
    fails=$((fails + 1))
    [ "$fails" -lt 5 ] || exit 1
  else
    fails=0
  fi
  sleep 5
done
