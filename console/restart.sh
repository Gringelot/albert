#!/bin/sh
# Restart the Albert Console (use this after changing server.mjs, lib/, or public/).
#
# Like restart.cmd, stop the listener first. A service manager can otherwise report success
# while the old server still owns port 4400 and keeps serving stale code.
set -eu

PORT=4400
LAUNCHD_LABEL=com.sdraugel.albert.console
SYSTEMD_UNIT=albert-console.service
USER_NAME=$(id -un)

info() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
listener_pid() {
  command -v lsof >/dev/null 2>&1 || die "lsof is required to restart Albert Console safely."
  for pid in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || :); do
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$owner" = "$USER_NAME" ] && { printf '%s\n' "$pid"; return 0; }
  done
  return 1
}

if old=$(listener_pid); then
  info "stopping node PID $old"
  kill "$old"
  sleep 2
else
  info "nothing listening on $PORT"
fi

case "$(uname -s)" in
  Darwin)
    PLIST=$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist
    [ -f "$PLIST" ] || die "Albert Console launchd agent is not installed. Run ./install.sh first."
    uid=$(id -u)
    launchctl bootout "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || :
    launchctl bootstrap "gui/$uid" "$PLIST"
    launchctl kickstart -k "gui/$uid/$LAUNCHD_LABEL"
    ;;
  Linux)
    systemctl --user enable "$SYSTEMD_UNIT"
    systemctl --user restart "$SYSTEMD_UNIT"
    ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac

sleep 2
if new=$(listener_pid); then
  info "restarted: node PID $new -> http://127.0.0.1:4400/"
else
  die "FAILED to come up. Check the Albert Console per-user service."
fi
