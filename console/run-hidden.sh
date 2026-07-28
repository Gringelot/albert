#!/bin/sh
# Hidden launcher counterpart for the Albert Console server, started by the per-user service.
# exec preserves node's exit code so launchd and systemd can supervise the real server process.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
NODE_PATH=${ALBERT_NODE_PATH:-node}
exec "$NODE_PATH" "$HERE/server.mjs" "$@"
