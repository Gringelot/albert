#!/bin/sh
# Albert Console on http://127.0.0.1:4400. Runs in the foreground: closing this terminal
# stops it, matching start.cmd on Windows.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
case "$(uname -s)" in
  Darwin) opener=open ;;
  Linux) opener=xdg-open ;;
  *) opener= ;;
esac

# Open the browser after a short delay so the server is already listening.
if [ -n "$opener" ] && command -v "$opener" >/dev/null 2>&1; then
  (sleep 1; "$opener" http://127.0.0.1:4400/ >/dev/null 2>&1) &
fi
exec node "$HERE/server.mjs" "$@"
