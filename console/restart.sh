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
# lsof is checked once at top level: a die() inside this function would only exit the
# command substitution, letting a missing lsof masquerade as "nothing is listening" and
# then as a restart failure on a perfectly healthy console.
command -v lsof >/dev/null 2>&1 || die "lsof is required to restart Albert Console safely."
listener_pid() {
  for pid in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || :); do
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$owner" = "$USER_NAME" ] && { printf '%s\n' "$pid"; return 0; }
  done
  return 1
}

if old=$(listener_pid); then
  info "stopping node PID $old"
  # || : so a server that exits on its own between the lsof and the kill does not abort
  # the restart under set -e.
  kill "$old" 2>/dev/null || :
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
    # A label disabled by stop.sh stays inert through bootstrap, so clear that first.
    launchctl enable "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || :
    launchctl bootstrap "gui/$uid" "$PLIST"
    launchctl kickstart -k "gui/$uid/$LAUNCHD_LABEL"
    ;;
  Linux)
    systemctl --user enable "$SYSTEMD_UNIT"
    systemctl --user restart "$SYSTEMD_UNIT"
    ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac

sleep 5
if new=$(listener_pid); then
  info "restarted: node PID $new -> http://127.0.0.1:$PORT/"
else
  die "FAILED to come up. Check the Albert Console per-user service."
fi
