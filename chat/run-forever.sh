#!/bin/sh
# Always-on supervisor for Albert Chat: launch Chainlit without a visible terminal dependency,
# relaunch on exit. Point a user launchd agent or systemd user unit at this file for autostart.
# Five consecutive fast exits (under 10s) mean something structural, like port 4401
# already being served or a broken venv: give up instead of spinning.
set -u

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PYTHON=$HERE/.venv/bin/python
[ -x "$PYTHON" ] || { printf '%s\n' 'Run setup.sh first.' >&2; exit 1; }
fails=0
while :; do
  started=$(date +%s)
  (
    cd "$HERE"
    # server:app, NOT `chainlit run`: server.py adds the Origin guard that stops a
    # drive-by page from hijacking the chat's WebSocket. See server.py.
    exec "$PYTHON" -m uvicorn server:app --host 127.0.0.1 --port 4401
  )
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -lt 10 ]; then
    fails=$((fails + 1))
    [ "$fails" -lt 5 ] || exit 1
  else
    fails=0
  fi
  sleep 5
done
