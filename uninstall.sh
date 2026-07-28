#!/bin/sh
# Removes Albert-owned Unix harness, Console, and per-user service state.
set -eu

DEFAULT_PORT=4400
DEFAULT_CHAT_PORT=4401
LAUNCHD_LABEL=com.sdraugel.albert.console
SYSTEMD_UNIT=albert-console.service
CONSOLE_MARKER=.albert-console-owner
CONSOLE_MARKER_CONTENT=albert-console-v1

# Prints an informational uninstaller message.
info() { printf '  %s\n' "$*"; }
# Prints a successful uninstaller message.
ok() { printf '  [ok] %s\n' "$*"; }
# Prints an actionable uninstaller warning.
warn() { printf '  [!] %s\n' "$*" >&2; }
# Stops before an ambiguous removal can affect unrelated files.
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Prints the supported command-line interface.
usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

  --claude-dir PATH   Claude Code config directory, default: $HOME/.claude
  --console-dir PATH  Console install directory, platform default
  --port N            Accepted for parity with install, default: 4400
  --chat-port N       Chat port to stop, default: 4401
  --no-task           Do not contact a per-user service manager
  --help              Show this help
EOF
}
# Rejects empty or option-like values for a required option.
option_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value"
  case "$2" in ''|--*) die "$1 requires a value" ;; esac
}
# Validates a TCP port before accepting the option.
validate_port() {
  case "$1" in ''|*[!0-9]*) die "--port must be an integer from 1 to 65535." ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "--port must be an integer from 1 to 65535."
}
# Rejects console paths whose lexical components could obscure a destructive target.
validate_console_dir() {
  case "$1" in *[!/]*) ;; *) die "--console-dir must name a specific directory." ;; esac
  case "$1" in //*) die "--console-dir must not use repeated leading slashes." ;; esac
  case "$1" in *'//'*) die "--console-dir must not contain repeated slashes." ;; esac
  case "$1" in */./*|*/.|*/../*|*/..) die "--console-dir must not contain . or .. path components." ;; esac
}
# Converts a user path to an absolute path before removing owned files.
absolute_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$ORIGINAL_DIR" "$1" ;; esac
}
# Rejects control characters that would make a removal target ambiguous.
validate_path() {
  case "$1" in ''|*'
'*|*"$CARRIAGE_RETURN"*) die "paths must not be empty or contain newlines." ;; esac
}
# Returns true only for a real Console directory carrying Albert's exact marker.
is_owned_console() {
  [ -d "$CONSOLE_DIR" ] && [ ! -L "$CONSOLE_DIR" ] && [ -f "$CONSOLE_DIR/$CONSOLE_MARKER" ] && [ "$(cat "$CONSOLE_DIR/$CONSOLE_MARKER")" = "$CONSOLE_MARKER_CONTENT" ]
}
# Refuses a recursive removal unless the existing directory was claimed by Albert.
verify_console_ownership() {
  if [ -e "$CONSOLE_DIR" ] || [ -L "$CONSOLE_DIR" ]; then
    is_owned_console || die "--console-dir is not an Albert Console directory, refusing to remove it."
  fi
}
# Removes Albert's per-user service registration without touching arbitrary processes.
remove_service() {
  case "$OS_NAME" in
    Darwin)
      command -v launchctl >/dev/null 2>&1 || die "launchctl is unavailable. Re-run with --no-task to remove files without a service."
      service_file=$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist
      uid=$(id -u)
      launchctl bootout "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || :
      rm -f "$service_file"
      ok "removed launchd agent $LAUNCHD_LABEL"
      ;;
    Linux)
      command -v systemctl >/dev/null 2>&1 || die "systemctl is unavailable. Re-run with --no-task to remove files without a service."
      service_file=$XDG_CONFIG_HOME/systemd/user/$SYSTEMD_UNIT
      systemctl --user disable "$SYSTEMD_UNIT" >/dev/null 2>&1 || :
      systemctl --user stop "$SYSTEMD_UNIT" >/dev/null 2>&1 || :
      rm -f "$service_file"
      systemctl --user daemon-reload
      ok "removed systemd user service $SYSTEMD_UNIT"
      ;;
    *) die "Unsupported OS: $OS_NAME. Re-run with --no-task to remove files without a service." ;;
  esac
}
# Stops an Albert run-forever supervisor before its server can be stopped.
stop_supervisor() {
  supervisor=$1
  [ -f "$supervisor" ] || return 0
  for pid in $(pgrep -f "$supervisor" 2>/dev/null || :); do
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$owner" = "$USER_NAME" ]; then
      kill "$pid" 2>/dev/null || :
      ok "stopped supervisor process $pid"
    fi
  done
}
# Stops only a listener owned by this user, never an arbitrary port owner.
stop_listener() {
  port=$1
  if ! command -v lsof >/dev/null 2>&1; then
    warn "lsof is unavailable; could not free port $port"
    return 0
  fi
  for pid in $(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || :); do
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$owner" = "$USER_NAME" ]; then
      kill "$pid" 2>/dev/null || :
      ok "stopped process $pid holding port $port"
    fi
  done
}
# Removes only the harness paths that this project owns.
remove_harness() {
  rm -rf "$CLAUDE_DIR/skills/albert"
  rm -f "$CLAUDE_DIR/workflows/chunk-exec.js"
  rm -f "$CLAUDE_DIR/agent-runs/_emit.mjs" "$CLAUDE_DIR/agent-runs/_inbox.mjs"
  for agent in loop-planner loop-worker loop-data-scientist loop-designer loop-researcher loop-devops loop-verifier-dev loop-qa loop-skeptic-research loop-cleanup loop-scribe; do
    rm -f "$CLAUDE_DIR/agents/$agent.md"
  done
  ok "removed Albert-owned harness files"
}

: "${HOME:?HOME is required}"
ORIGINAL_DIR=$(pwd -P)
CARRIAGE_RETURN=$(printf '\r')
CLAUDE_DIR=$HOME/.claude
PORT=$DEFAULT_PORT
CHAT_PORT=$DEFAULT_CHAT_PORT
REPO=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
OS_NAME=$(uname -s)
case "$OS_NAME" in
  Darwin) CONSOLE_DIR=$HOME/Library/Application\ Support/AlbertConsole ;;
  Linux) CONSOLE_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/albert-console ;;
  *) die "Unsupported OS: $OS_NAME." ;;
esac
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
NO_TASK=false
USER_NAME=$(id -un)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-dir) option_value "$@"; CLAUDE_DIR=$2; shift 2 ;;
    --console-dir) option_value "$@"; CONSOLE_DIR=$2; shift 2 ;;
    --port) option_value "$@"; PORT=$2; shift 2 ;;
    --chat-port) option_value "$@"; CHAT_PORT=$2; shift 2 ;;
    --no-task) NO_TASK=true; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

validate_port "$PORT"
validate_port "$CHAT_PORT"
validate_path "$CLAUDE_DIR"
validate_path "$CONSOLE_DIR"
CLAUDE_DIR=$(absolute_path "$CLAUDE_DIR")
CONSOLE_DIR=$(absolute_path "$CONSOLE_DIR")
validate_console_dir "$CONSOLE_DIR"
verify_console_ownership
printf '\nRemoving Albert\n'
info "ClaudeDir  : $CLAUDE_DIR"
info "ConsoleDir : $CONSOLE_DIR"
if [ "$NO_TASK" = false ]; then
  remove_service
else
  info "service removal skipped (--no-task)"
fi
stop_supervisor "$CONSOLE_DIR/run-forever.sh"
stop_supervisor "$REPO/chat/run-forever.sh"
stop_listener "$PORT"
stop_listener "$CHAT_PORT"
if [ -e "$CONSOLE_DIR" ]; then
  rm -rf "$CONSOLE_DIR"
  ok "removed console at $CONSOLE_DIR"
else
  info "no console install found at $CONSOLE_DIR"
fi
remove_harness
warn "left generic helper agents and run history in place"
printf '\nDone.\n'
