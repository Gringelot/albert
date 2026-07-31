#!/bin/sh
# Albert Console on http://127.0.0.1:4400. Runs in the foreground: closing this terminal
# stops it, matching start.cmd on Windows.
set -eu

# install.sh rewrites this line so a --port install serves, opens, and stops one port.
PORT=4400
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
case "$(uname -s)" in
  Darwin) opener=open ;;
  Linux) opener=xdg-open ;;
  *) opener= ;;
esac

# Open the browser after a short delay so the server is already listening.
if [ -n "$opener" ] && command -v "$opener" >/dev/null 2>&1; then
  (sleep 1; "$opener" "http://127.0.0.1:$PORT/" >/dev/null 2>&1) &
fi
# "$@" first: server.mjs takes the first occurrence of a flag, so an explicitly passed
# --port still wins over the installed default.
exec node "$HERE/server.mjs" "$@" --port "$PORT"
