#!/bin/sh
# Installs the Albert harness and optional per-user Console service on macOS or Linux.
set -eu

NODE_MIN_MAJOR=20
DEFAULT_PORT=4400
LAUNCHD_LABEL=com.sdraugel.albert.console
SYSTEMD_UNIT=albert-console.service
CONSOLE_MARKER=.albert-console-owner
CONSOLE_MARKER_CONTENT=albert-console-v1

# Prints an informational installer message.
info() { printf '  %s\n' "$*"; }
# Prints a successful installer message.
ok() { printf '  [ok] %s\n' "$*"; }
# Prints an actionable installer warning.
warn() { printf '  [!] %s\n' "$*" >&2; }
# Stops before an incomplete install can leave misleading state.
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Prints the supported command-line interface.
usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  --claude-dir PATH     Claude Code config directory, default: $HOME/.claude
  --projects-dir PATH   Project root context, default: parent of this repo
  --console-dir PATH    Console install directory, platform default
  --port N              Console port, default: 4400
  --demo-only           Generate demo data and run the console in the foreground
  --no-console          Install the harness only
  --no-task             Do not register the per-user Console service
  --help                Show this help
EOF
}
# Rejects empty or option-like values for a required option.
option_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value"
  case "$2" in ''|--*) die "$1 requires a value" ;; esac
}
# Confirms Node is available, supported, and addressable by an absolute path.
require_node() {
  command -v node >/dev/null 2>&1 || die "Node.js is not on PATH. Install Node $NODE_MIN_MAJOR+ and re-run."
  NODE_PATH=$(command -v node)
  case "$NODE_PATH" in /*) ;; *) die "Node.js must resolve to an absolute path." ;; esac
  NODE_VERSION=$($NODE_PATH --version)
  NODE_MAJOR=${NODE_VERSION#v}
  NODE_MAJOR=${NODE_MAJOR%%.*}
  case "$NODE_MAJOR" in ''|*[!0-9]*) die "Could not determine the Node.js version." ;; esac
  [ "$NODE_MAJOR" -ge "$NODE_MIN_MAJOR" ] || die "Node.js $NODE_MIN_MAJOR+ is required, found $NODE_VERSION."
}
# Validates a TCP port before it reaches a service definition.
validate_port() {
  case "$1" in ''|*[!0-9]*) die "--port must be an integer from 1 to 65535." ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "--port must be an integer from 1 to 65535."
}
# Converts a user path to an absolute path before it reaches a service definition.
absolute_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$ORIGINAL_DIR" "$1" ;; esac
}
# Rejects control characters that cannot safely form a service configuration value.
validate_path() {
  case "$1" in ''|*'
'*|*"$CARRIAGE_RETURN"*) die "paths must not be empty or contain newlines." ;; esac
}
# Rejects console paths whose lexical components could obscure a destructive target.
validate_console_dir() {
  case "$1" in *[!/]*) ;; *) die "--console-dir must name a specific directory." ;; esac
  case "$1" in //*) die "--console-dir must not use repeated leading slashes." ;; esac
  case "$1" in *'//'*) die "--console-dir must not contain repeated slashes." ;; esac
  case "$1" in */./*|*/.|*/../*|*/..) die "--console-dir must not contain . or .. path components." ;; esac
}
# Returns true only for a real Console directory carrying Albert's exact marker.
is_owned_console() {
  [ -d "$CONSOLE_DIR" ] && [ ! -L "$CONSOLE_DIR" ] && [ -f "$CONSOLE_DIR/$CONSOLE_MARKER" ] && [ "$(cat "$CONSOLE_DIR/$CONSOLE_MARKER")" = "$CONSOLE_MARKER_CONTENT" ]
}
# Returns true when a directory has no entries other than . and ... .
directory_is_empty() {
  for entry in "$1"/.[!.]* "$1"/..?* "$1"/*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then return 1; fi
  done
  return 0
}
# Claims an empty dedicated directory before Albert writes any Console files into it.
prepare_console_dir() {
  if [ -e "$CONSOLE_DIR" ] || [ -L "$CONSOLE_DIR" ]; then
    [ -d "$CONSOLE_DIR" ] && [ ! -L "$CONSOLE_DIR" ] || die "--console-dir must be a real directory."
    if ! is_owned_console; then
      directory_is_empty "$CONSOLE_DIR" || die "--console-dir is non-empty and is not an Albert Console directory. Choose an empty directory or a previously installed Albert Console directory."
    fi
  else
    mkdir -p "$CONSOLE_DIR"
  fi
  if ! is_owned_console; then
    printf '%s\n' "$CONSOLE_MARKER_CONTENT" >"$CONSOLE_DIR/$CONSOLE_MARKER"
    chmod 600 "$CONSOLE_DIR/$CONSOLE_MARKER"
  fi
}
# Renders an owned harness file into a Unix-safe installed copy.
install_template() {
  source_file=$1
  destination_file=$2
  template_kind=$3
  "$NODE_PATH" "$REPO/tools/render-unix-install.mjs" template "$source_file" "$destination_file" "$CLAUDE_DIR" "$PROJECTS_DIR" "$CONSOLE_DIR" "$template_kind"
}
# Copies the console tree while preserving its relative layout.
install_console() {
  find "$REPO/console" -type f -exec sh -c '
    source_file=$1
    source_root=$2
    destination_root=$3
    relative=${source_file#"$source_root"/}
    destination_file=$destination_root/$relative
    mkdir -p "$(dirname "$destination_file")"
    cp "$source_file" "$destination_file"
  ' sh {} "$REPO/console" "$CONSOLE_DIR" \;
  find "$CONSOLE_DIR" -type f -name '*.sh' -exec chmod 700 {} \;
}
# Installs all loop agents and only missing generic helper agents.
install_agents() {
  for source_file in "$REPO"/harness/agents/*.md; do
    name=${source_file##*/}
    destination_file=$CLAUDE_DIR/agents/$name
    case "$name" in
      code-reviewer.md|security-reviewer.md|performance-reviewer.md|doc-writer.md|refactor-worker.md|codebase-locator.md)
        if [ -e "$destination_file" ]; then
          skipped_helpers="${skipped_helpers}${skipped_helpers:+, }${name%.md}"
          continue
        fi
        ;;
    esac
    install_template "$source_file" "$destination_file" markdown
  done
}
# Registers the Console with the detected per-user service manager.
register_service() {
  store_path=$CLAUDE_DIR/agent-runs
  agents_path=$CLAUDE_DIR/agents
  # --projects is the Claude Code transcripts root the session tailer reads, NOT the
  # code-projects context dir ($PROJECTS_DIR only parameterizes harness prompts).
  transcripts_path=$CLAUDE_DIR/projects
  runner_path=$CONSOLE_DIR/run-hidden.sh
  case "$OS_NAME" in
    Darwin)
      command -v launchctl >/dev/null 2>&1 || die "launchctl is unavailable. Re-run with --no-task to install without a service."
      service_file=$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist
      mkdir -p "$(dirname "$service_file")"
      uid=$(id -u)
      launchctl bootout "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || :
      "$NODE_PATH" "$REPO/tools/render-unix-install.mjs" launchd "$service_file" "$LAUNCHD_LABEL" "$NODE_PATH" "$runner_path" "$PORT" "$store_path" "$transcripts_path" "$agents_path" "$CONSOLE_DIR" "$CONSOLE_DIR/albert-console.log" "$CONSOLE_DIR/albert-console-error.log"
      chmod 600 "$service_file"
      launchctl bootstrap "gui/$uid" "$service_file"
      launchctl kickstart -k "gui/$uid/$LAUNCHD_LABEL"
      ok "registered launchd agent $LAUNCHD_LABEL -> http://localhost:$PORT"
      ;;
    Linux)
      command -v systemctl >/dev/null 2>&1 || die "systemctl is unavailable. Re-run with --no-task to install without a service."
      service_file=$XDG_CONFIG_HOME/systemd/user/$SYSTEMD_UNIT
      "$NODE_PATH" "$REPO/tools/render-unix-install.mjs" systemd "$service_file" "$NODE_PATH" "$runner_path" "$PORT" "$store_path" "$transcripts_path" "$agents_path" "$CONSOLE_DIR"
      systemctl --user daemon-reload
      systemctl --user enable "$SYSTEMD_UNIT"
      systemctl --user restart "$SYSTEMD_UNIT"
      ok "registered systemd user service $SYSTEMD_UNIT -> http://localhost:$PORT"
      ;;
    *) die "Unsupported OS: $OS_NAME. Re-run with --no-task to install without a service." ;;
  esac
}
# Runs the foreground synthetic-data demonstration without installing files.
run_demo() {
  demo_dir=$REPO/tools/demo-out
  info "Generating synthetic demo data"
  "$NODE_PATH" "$REPO/tools/make-demo-data.mjs" "$demo_dir"
  ok "demo data at $demo_dir"
  case "$OS_NAME" in
    Darwin) opener=open ;;
    Linux) opener=xdg-open ;;
    *) opener= ;;
  esac
  if [ -n "$opener" ] && command -v "$opener" >/dev/null 2>&1; then
    "$opener" "http://localhost:$PORT" >/dev/null 2>&1 &
  else
    warn "no browser opener found, open http://localhost:$PORT yourself"
  fi
  info "Starting the console at http://localhost:$PORT (Ctrl+C to stop)"
  exec "$NODE_PATH" "$REPO/console/server.mjs" --port "$PORT" --store "$demo_dir/agent-runs" --projects "$demo_dir/projects" --agents "$REPO/harness/agents"
}

: "${HOME:?HOME is required}"
REPO=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ORIGINAL_DIR=$(pwd -P)
CARRIAGE_RETURN=$(printf '\r')
CLAUDE_DIR=$HOME/.claude
PROJECTS_DIR=$(CDPATH= cd "$REPO/.." && pwd -P)
PORT=$DEFAULT_PORT
OS_NAME=$(uname -s)
case "$OS_NAME" in
  Darwin) CONSOLE_DIR=$HOME/Library/Application\ Support/AlbertConsole ;;
  Linux) CONSOLE_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/albert-console ;;
  *) die "Unsupported OS: $OS_NAME." ;;
esac
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
DEMO_ONLY=false
NO_CONSOLE=false
NO_TASK=false
skipped_helpers=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-dir) option_value "$@"; CLAUDE_DIR=$2; shift 2 ;;
    --projects-dir) option_value "$@"; PROJECTS_DIR=$2; shift 2 ;;
    --console-dir) option_value "$@"; CONSOLE_DIR=$2; shift 2 ;;
    --port) option_value "$@"; PORT=$2; shift 2 ;;
    --demo-only) DEMO_ONLY=true; shift ;;
    --no-console) NO_CONSOLE=true; shift ;;
    --no-task) NO_TASK=true; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

validate_port "$PORT"
validate_path "$CLAUDE_DIR"
validate_path "$PROJECTS_DIR"
validate_path "$CONSOLE_DIR"
CLAUDE_DIR=$(absolute_path "$CLAUDE_DIR")
PROJECTS_DIR=$(absolute_path "$PROJECTS_DIR")
CONSOLE_DIR=$(absolute_path "$CONSOLE_DIR")
validate_console_dir "$CONSOLE_DIR"
require_node
if [ "$DEMO_ONLY" = true ]; then
  [ "$NO_CONSOLE" = false ] && [ "$NO_TASK" = false ] || die "--demo-only cannot be combined with install options."
  run_demo
fi

if [ "$NO_CONSOLE" = false ]; then
  prepare_console_dir
fi

printf '\nInstalling Albert\n'
info "ClaudeDir   : $CLAUDE_DIR"
info "ProjectsDir : $PROJECTS_DIR"
info "ConsoleDir  : $CONSOLE_DIR"
printf '\nInstalling harness into Claude Code config\n'
install_template "$REPO/harness/skills/albert/SKILL.md" "$CLAUDE_DIR/skills/albert/SKILL.md" markdown
ok "skill: /albert"
install_agents
ok "agents: 11 loop-* roster + generic helpers"
[ -z "$skipped_helpers" ] || info "kept your existing helper agents: $skipped_helpers"
install_template "$REPO/harness/workflows/chunk-exec.js" "$CLAUDE_DIR/workflows/chunk-exec.js" workflow
ok "workflow: chunk-exec (parallel executor)"
mkdir -p "$CLAUDE_DIR/agent-runs"
cp "$REPO/harness/runtime/_emit.mjs" "$CLAUDE_DIR/agent-runs/_emit.mjs"
cp "$REPO/harness/runtime/_inbox.mjs" "$CLAUDE_DIR/agent-runs/_inbox.mjs"
cp "$REPO/harness/runtime/agent-runs-README.md" "$CLAUDE_DIR/agent-runs/README.md"
ok "run store: _emit.mjs + _inbox.mjs + README (existing run data left untouched)"

if [ "$NO_CONSOLE" = false ]; then
  printf '\nInstalling Albert Console\n'
  install_console
  ok "console installed at $CONSOLE_DIR"
  if [ "$NO_TASK" = false ]; then
    register_service
  else
    info "console service not registered (--no-task). Start it manually with: $NODE_PATH $CONSOLE_DIR/server.mjs"
  fi
fi

printf '\nInstalled.\n'
info 'Run a goal from any project:  /albert "<your goal>"'
[ "$NO_CONSOLE" = true ] || [ "$NO_TASK" = true ] || info "Watch it live:                http://localhost:$PORT"
info 'Chat UI (optional):           see chat/README.md (repo-local, requires Python 3.12)'
info 'Remove everything:            ./uninstall.sh'
