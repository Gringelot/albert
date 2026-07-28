#!/bin/sh
# One-time setup for Albert Chat. Requires Python 3.12.
# The venv is built from 3.12 explicitly: the default python may be newer than Chainlit supports.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PYTHON=$HERE/.venv/bin/python
if [ ! -x "$PYTHON" ]; then
  command -v python3.12 >/dev/null 2>&1 || {
    printf '%s\n' 'Python 3.12 not found: install it, then re-run setup.sh.' >&2
    exit 1
  }
  python3.12 -m venv "$HERE/.venv" || exit 1
fi
"$PYTHON" --version | grep ' 3\.12' >/dev/null || {
  printf '%s\n' 'chat/.venv is not Python 3.12. Delete it and re-run setup.sh.' >&2
  exit 1
}
"$PYTHON" -m pip install --disable-pip-version-check -r "$HERE/requirements.txt" || exit 1
printf '\nDone. Start the chat UI with start.sh\n'
