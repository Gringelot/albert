#!/bin/sh
# Launch a detached, visible Claude Code session running an /albert goal.
#
# Invoked by the chat backend as:
#   sh launch_run.sh <project> <prompt>
#
# Why this wrapper exists: macOS Terminal and Ubuntu's x-terminal-emulator need platform
# specific launch commands, while this script keeps project and prompt argument boundaries clean.
# The prompt must not contain double quotes (the caller strips them).
set -eu

[ "$#" -eq 2 ] || { printf '%s\n' 'usage: launch_run.sh <project> <prompt>' >&2; exit 1; }
PROJECT=$1
PROMPT=$2

[ -d "$PROJECT" ] || { printf 'project directory not found: %s\n' "$PROJECT" >&2; exit 1; }
case "$PROMPT" in *'"'*) printf '%s\n' 'prompt must not contain double quotes' >&2; exit 1 ;; esac
command -v claude >/dev/null 2>&1 || { printf '%s\n' 'claude CLI not found on PATH' >&2; exit 1; }

case "$(uname -s)" in
  Darwin)
    command -v osascript >/dev/null 2>&1 || { printf '%s\n' 'Terminal automation is unavailable.' >&2; exit 1; }
    exec osascript - "$PROJECT" "$PROMPT" <<'APPLESCRIPT'
on run argv
  set projectPath to item 1 of argv
  set promptText to item 2 of argv
  tell application "Terminal"
    activate
    do script "cd " & quoted form of projectPath & " && exec claude -- " & quoted form of promptText
  end tell
end run
APPLESCRIPT
    ;;
  Linux)
    command -v x-terminal-emulator >/dev/null 2>&1 || { printf '%s\n' 'x-terminal-emulator is required to launch a visible Albert run.' >&2; exit 1; }
    cd "$PROJECT"
    # Detach rather than exec: the chat backend calls this with a 60s timeout, and a
    # non-daemonizing emulator (xterm, alacritty, kitty) runs for the life of the session.
    # Blocking would time out and kill the terminal, destroying the run it just started.
    # The macOS branch already returns immediately because osascript does.
    setsid x-terminal-emulator -e claude -- "$PROMPT" >/dev/null 2>&1 &
    exit 0
    ;;
  *) printf 'unsupported OS: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
