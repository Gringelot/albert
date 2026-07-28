#!/bin/sh
# Stop Albert Chat for good. Kill the run-forever supervisor first if one is running,
# otherwise it relaunches the server within seconds; then kill the port owner.
set -eu

PORT=4401
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
SUPERVISOR=$HERE/run-forever.sh
USER_NAME=$(id -un)

info() { printf '%s\n' "$*"; }
listener_pid() {
  command -v lsof >/dev/null 2>&1 || return 1
  for pid in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || :); do
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$owner" = "$USER_NAME" ] && { printf '%s\n' "$pid"; return 0; }
  done
  return 1
}

for pid in $(pgrep -f "$SUPERVISOR" 2>/dev/null || :); do
  owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ "$owner" = "$USER_NAME" ]; then
    kill "$pid" 2>/dev/null || :
    info "supervisor stopped"
  fi
done

if pid=$(listener_pid); then
  kill "$pid"
  info "chat stopped"
else
  info "chat was not running"
fi
