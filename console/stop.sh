#!/bin/sh
# Stop the Albert Console for good, whichever always-on mechanism is in use.
# Order matters: silence the revive mechanisms first, then kill the port owner directly:
# killing only the launcher leaves node orphaned on port 4400.
set -eu

PORT=4400
LAUNCHD_LABEL=com.sdraugel.albert.console
SYSTEMD_UNIT=albert-console.service
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

case "$(uname -s)" in
  Darwin)
    uid=$(id -u)
    launchctl bootout "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || :
    info "launchd agent stopped"
    ;;
  Linux)
    systemctl --user disable --now "$SYSTEMD_UNIT" >/dev/null 2>&1 || :
    info "systemd user service stopped"
    ;;
esac

# Literal substring match: pgrep -f would treat the path as a regular expression.
ps -Ao pid=,user=,command= 2>/dev/null | while read -r pid owner command; do
  [ "$owner" = "$USER_NAME" ] || continue
  case "$command" in
    *"$SUPERVISOR"*)
      kill "$pid" 2>/dev/null || :
      info "supervisor stopped"
      ;;
  esac
done

if pid=$(listener_pid); then
  kill "$pid"
  info "server stopped"
else
  info "server was not running"
fi
