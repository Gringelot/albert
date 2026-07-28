#!/bin/sh
# Albert Chat on http://127.0.0.1:4401. Runs in the foreground: closing this terminal
# stops it, matching start.cmd on Windows.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PYTHON=$HERE/.venv/bin/python
[ -x "$PYTHON" ] || { printf '%s\n' 'Run setup.sh first.' >&2; exit 1; }
case "$(uname -s)" in
  Darwin) opener=open ;;
  Linux) opener=xdg-open ;;
  *) opener= ;;
esac

# Open the browser after a short delay so the server is already listening.
if [ -n "$opener" ] && command -v "$opener" >/dev/null 2>&1; then
  (sleep 2; "$opener" http://127.0.0.1:4401/ >/dev/null 2>&1) &
fi
# Served through server.py, NOT `chainlit run`: it adds the Origin guard that stops
# any page you happen to be browsing from hijacking the chat's WebSocket. See server.py.
cd "$HERE"
exec "$PYTHON" -m uvicorn server:app --host 127.0.0.1 --port 4401 "$@"
