#!/bin/sh
# Isolated smoke suite for the Unix (macOS/Linux) port.
#
# Safe by construction: every stateful check runs against a throwaway HOME under
# mktemp, with launchctl/osascript/claude/open shadowed by PATH stubs, so it never
# touches the real ~/.claude, never registers a real service, and never opens an
# app or browser. The console boots on a test port (default 4499) and is killed
# on exit. Implements the verification list in
# docs/superpowers/specs/2026-07-28-unix-parity-design.md.
#
# Usage: sh tools/test-unix.sh          (from anywhere; paths are repo-relative)
# Exit:  0 all checks passed, 1 otherwise.
set -u

REPO=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
TEST_PORT=${ALBERT_TEST_PORT:-4499}
PASS=0
FAIL=0
SERVER_PID=

# macOS TMPDIR ends with a slash; strip it or every derived path carries '//',
# which the installer's path validation rightly rejects.
TMPBASE=${TMPDIR:-/tmp}
TMPBASE=${TMPBASE%/}
TMPROOT=$(mktemp -d "$TMPBASE/albert-test.XXXXXX") || exit 1
FAKE_HOME=$TMPROOT/home
STUB_BIN=$TMPROOT/bin
STUB_LOG=$TMPROOT/stub.log
mkdir -p "$FAKE_HOME" "$STUB_BIN"

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT INT TERM

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
# Asserts a command succeeds quietly; logs output on failure.
check() {
  label=$1; shift
  if out=$("$@" 2>&1); then ok "$label"; else bad "$label: $out"; fi
}
# Asserts a command FAILS (validation-rejection tests).
check_fails() {
  label=$1; shift
  if out=$("$@" 2>&1); then bad "$label: expected failure, got success"; else ok "$label"; fi
}
# Asserts a file contains a fixed string.
check_grep() {
  label=$1; pattern=$2; file=$3
  if grep -F -q "$pattern" "$file" 2>/dev/null; then ok "$label"; else bad "$label (no '$pattern' in $file)"; fi
}
# Asserts a file does NOT contain a fixed string.
check_absent() {
  label=$1; pattern=$2; file=$3
  if grep -F -q "$pattern" "$file" 2>/dev/null; then bad "$label ('$pattern' present in $file)"; else ok "$label"; fi
}

# ---- PATH stubs: shadow every command that could touch real system state ----
cat >"$STUB_BIN/launchctl" <<EOF
#!/bin/sh
printf 'launchctl %s\n' "\$*" >>"$STUB_LOG"
exit 0
EOF
cat >"$STUB_BIN/osascript" <<EOF
#!/bin/sh
cat >/dev/null
printf 'osascript %s\n' "\$*" >>"$STUB_LOG"
exit 0
EOF
cat >"$STUB_BIN/claude" <<EOF
#!/bin/sh
printf 'claude %s\n' "\$*" >>"$STUB_LOG"
[ "\${1:-}" = auth ] && printf '{"loggedIn":false}\n'
exit 0
EOF
cat >"$STUB_BIN/open" <<EOF
#!/bin/sh
printf 'open %s\n' "\$*" >>"$STUB_LOG"
exit 0
EOF
chmod 700 "$STUB_BIN"/*
SAFE_PATH=$STUB_BIN:$PATH

say ''
say '== 1. Static checks =='
for f in install.sh uninstall.sh console/*.sh chat/*.sh; do
  check "sh -n $f" sh -n "$REPO/$f"
done
for f in tools/render-unix-install.mjs tools/make-demo-data.mjs console/server.mjs \
         console/lib/*.mjs harness/runtime/_emit.mjs harness/runtime/_inbox.mjs \
         harness/workflows/chunk-exec.js; do
  check "node --check $f" node --check "$REPO/$f"
done
if command -v python3 >/dev/null 2>&1; then
  for f in "$REPO"/chat/*.py; do
    check "py_compile ${f##*/}" python3 -m py_compile "$f"
  done
else
  say '  skip python static checks: python3 not found'
fi

say ''
say '== 2. Renderer output is Unix-clean =='
RENDER_OUT=$TMPROOT/render
node "$REPO/tools/render-unix-install.mjs" template "$REPO/harness/skills/albert/SKILL.md" \
  "$RENDER_OUT/SKILL.md" "$FAKE_HOME/.claude" "$FAKE_HOME/code" "$FAKE_HOME/console" markdown
check_absent 'rendered SKILL has no template tokens' '{{' "$RENDER_OUT/SKILL.md"
check_absent 'rendered SKILL has no backslashes' '\' "$RENDER_OUT/SKILL.md"
check_absent 'rendered SKILL has no powershell tool' 'powershell' "$RENDER_OUT/SKILL.md"
check_absent 'rendered SKILL has no init.ps1' 'init.ps1' "$RENDER_OUT/SKILL.md"
check_absent 'rendered SKILL has NO blanket sh grant' 'Bash(sh *)' "$RENDER_OUT/SKILL.md"
check_grep 'rendered SKILL grants only the run bootstrap sh' "Bash(sh $FAKE_HOME/.claude/agent-runs/*/init.sh)" "$RENDER_OUT/SKILL.md"
check_grep 'rendered SKILL grants the quoted bootstrap form' "Bash(sh '$FAKE_HOME/.claude/agent-runs/*/init.sh')" "$RENDER_OUT/SKILL.md"
check_grep 'rendered SKILL grants python3' 'Bash(python3 *)' "$RENDER_OUT/SKILL.md"
# Control characters cannot be safely escaped into a systemd unit; the renderer must
# refuse rather than emit a definition an injected newline could extend.
NEWLINE_PAYLOAD=$(printf '/tmp/x\n[Service]\nExecStart=/bin/sh -c evil')
check_fails 'renderer rejects control chars in a systemd value' \
  node "$REPO/tools/render-unix-install.mjs" systemd "$TMPROOT/evil.service" /usr/bin/node /r.sh 4400 /s /p /a "$NEWLINE_PAYLOAD"
check_fails 'no systemd unit written when rejected' test -e "$TMPROOT/evil.service"
check_fails 'renderer rejects control chars in a plist value' \
  node "$REPO/tools/render-unix-install.mjs" launchd "$TMPROOT/evil.plist" lbl /usr/bin/node /r.sh 4400 /s /p /a "$NEWLINE_PAYLOAD" /o.log /e.log
check_fails 'no plist written when rejected' test -e "$TMPROOT/evil.plist"
node "$REPO/tools/render-unix-install.mjs" template "$REPO/harness/workflows/chunk-exec.js" \
  "$RENDER_OUT/chunk-exec.js" "$FAKE_HOME/.claude" "$FAKE_HOME/code" "$FAKE_HOME/console" workflow
check_grep 'rendered workflow STORE is absolute unix path' "\"$FAKE_HOME/.claude/agent-runs\"" "$RENDER_OUT/chunk-exec.js"
check_absent 'rendered workflow has no template tokens' '{{' "$RENDER_OUT/chunk-exec.js"
check 'rendered workflow still parses' node --check "$RENDER_OUT/chunk-exec.js"

say ''
say '== 3. Installer in isolated HOME (stubbed launchctl, no real services) =='
check 'install.sh full install' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh"
CLAUDE_DIR=$FAKE_HOME/.claude
case "$(uname -s)" in
  Darwin) CONSOLE_DIR="$FAKE_HOME/Library/Application Support/AlbertConsole" ;;
  *)      CONSOLE_DIR=$FAKE_HOME/.local/share/albert-console ;;
esac
check 'skill installed' test -f "$CLAUDE_DIR/skills/albert/SKILL.md"
check_absent 'installed SKILL is rendered (no tokens)' '{{' "$CLAUDE_DIR/skills/albert/SKILL.md"
check 'workflow installed' test -f "$CLAUDE_DIR/workflows/chunk-exec.js"
check 'emit helper installed' test -f "$CLAUDE_DIR/agent-runs/_emit.mjs"
check 'inbox helper installed' test -f "$CLAUDE_DIR/agent-runs/_inbox.mjs"
check 'store README installed' test -f "$CLAUDE_DIR/agent-runs/README.md"
LOOP_AGENTS=0
for a in loop-planner loop-worker loop-data-scientist loop-designer loop-researcher \
         loop-devops loop-verifier-dev loop-qa loop-skeptic-research loop-cleanup loop-scribe; do
  [ -f "$CLAUDE_DIR/agents/$a.md" ] && LOOP_AGENTS=$((LOOP_AGENTS + 1))
done
if [ "$LOOP_AGENTS" -eq 11 ]; then ok 'all 11 loop agents installed'; else bad "loop agents installed: $LOOP_AGENTS/11"; fi
check 'generic helper agent installed' test -f "$CLAUDE_DIR/agents/code-reviewer.md"
check 'console marker present' test -f "$CONSOLE_DIR/.albert-console-owner"
check 'console server copied' test -f "$CONSOLE_DIR/server.mjs"
if [ -x "$CONSOLE_DIR/run-hidden.sh" ]; then ok 'console scripts executable'; else bad 'console scripts not executable'; fi

PLIST=$FAKE_HOME/Library/LaunchAgents/com.sdraugel.albert.console.plist
if [ "$(uname -s)" = Darwin ]; then
  check 'launchd plist written' test -f "$PLIST"
  # Regression guard for the --projects fix: the service must tail the Claude
  # transcripts root, not the code-projects context dir.
  if grep -A1 '<string>--projects</string>' "$PLIST" | grep -F -q "$CLAUDE_DIR/projects"; then
    ok 'service --projects points at transcripts root'
  else
    bad "service --projects is wrong: $(grep -A1 -- '--projects' "$PLIST" | tail -1)"
  fi
  check_grep 'service --store points at run store' "$CLAUDE_DIR/agent-runs" "$PLIST"
  check_grep 'stubbed launchctl bootstrapped service' 'launchctl bootstrap' "$STUB_LOG"
fi

say ''
say '== 4. Installer validation rejections =='
check 'second install is idempotent' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --no-task
check_fails 'rejects invalid port' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --port 99999 --no-task
check_fails 'rejects port with junk' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --port 44x --no-task
mkdir -p "$TMPROOT/dirty" && touch "$TMPROOT/dirty/keep.txt"
check_fails 'rejects non-empty unowned console dir' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --console-dir "$TMPROOT/dirty" --no-task
check_fails 'rejects root as console dir' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --console-dir / --no-task
check_fails 'rejects console dir with dot-dot' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/install.sh" --console-dir "$TMPROOT/a/../b" --no-task
check 'dirty dir untouched by rejection' test -f "$TMPROOT/dirty/keep.txt"

say ''
say '== 5. Run-store helpers (_emit / _inbox) in isolated HOME =='
STORE=$CLAUDE_DIR/agent-runs
RUN=smoke-test-2026-07-31
mkdir -p "$STORE/$RUN"
printf '{"active_run_id":"%s","runs":[{"id":"%s","project_path":"%s","status":"running"}]}\n' \
  "$RUN" "$RUN" "$TMPROOT" >"$STORE/index.json"
check 'emit appends an event' env HOME="$FAKE_HOME" node "$STORE/_emit.mjs" "$RUN" task.picked controller T1 'smoke emit' --iter 1
check 'events.jsonl exists' test -f "$STORE/$RUN/events.jsonl"
check 'emitted event is valid JSON with type' env HOME="$FAKE_HOME" node -e "
  const l=require('fs').readFileSync('$STORE/$RUN/events.jsonl','utf8').trim().split('\n')[0];
  const e=JSON.parse(l);
  if (e.type!=='task.picked'||e.actor!=='controller') process.exit(1);"
check 'inbox write queues a message' env HOME="$FAKE_HOME" node "$STORE/_inbox.mjs" write "$RUN" --type info --text 'smoke message'
MSG_FILE=$(ls "$STORE/$RUN/inbox/"*.json 2>/dev/null | head -1)
if [ -n "$MSG_FILE" ]; then ok 'inbox message file created'; else bad 'inbox message file missing'; fi
check 'inbox list shows the message' env HOME="$FAKE_HOME" node "$STORE/_inbox.mjs" list "$RUN"
if [ -n "$MSG_FILE" ]; then
  check 'inbox reply archives the message' env HOME="$FAKE_HOME" node "$STORE/_inbox.mjs" reply "$RUN" "$(basename "$MSG_FILE")" --text 'smoke reply'
  check 'message moved to processed' test -f "$STORE/$RUN/inbox/processed/$(basename "$MSG_FILE")"
  check_grep 'chat.msg event recorded' 'chat.msg' "$STORE/$RUN/events.jsonl"
  check_grep 'chat.reply event recorded' 'chat.reply' "$STORE/$RUN/events.jsonl"
fi

say ''
say '== 6. Demo data + live console on 127.0.0.1:'"$TEST_PORT"' =='
DEMO=$TMPROOT/demo
check 'demo data generates' node "$REPO/tools/make-demo-data.mjs" "$DEMO"
env HOME="$FAKE_HOME" PATH="$SAFE_PATH" node "$REPO/console/server.mjs" --port "$TEST_PORT" \
  --store "$DEMO/agent-runs" --projects "$DEMO/projects" --agents "$REPO/harness/agents" \
  >"$TMPROOT/server.log" 2>&1 &
SERVER_PID=$!
i=0
while [ "$i" -lt 20 ]; do
  curl -fsS -o /dev/null "http://127.0.0.1:$TEST_PORT/" 2>/dev/null && break
  i=$((i + 1)); sleep 0.5
done
check 'GET / serves the UI' curl -fsS -o "$TMPROOT/index.html" "http://127.0.0.1:$TEST_PORT/"
check_grep 'UI looks like the console' '<title' "$TMPROOT/index.html"
for api in roster runs sessions usage; do
  check "GET /api/$api" curl -fsS -o "$TMPROOT/$api.json" "http://127.0.0.1:$TEST_PORT/api/$api"
  check "api/$api is JSON" node -e "JSON.parse(require('fs').readFileSync('$TMPROOT/$api.json','utf8'))"
done
SSE_HEAD=$(curl -si --max-time 2 "http://127.0.0.1:$TEST_PORT/events" 2>/dev/null | head -15 || :)
case "$SSE_HEAD" in
  *text/event-stream*) ok '/events is an SSE stream' ;;
  *) bad "/events content-type wrong: $SSE_HEAD" ;;
esac
if lsof -nP -a -p "$SERVER_PID" -iTCP -sTCP:LISTEN 2>/dev/null | grep -q '127.0.0.1'; then
  ok 'server bound to 127.0.0.1 only'
else
  bad 'server not bound to loopback (or lsof failed)'
fi
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=
ok 'server stopped'

say ''
say '== 7. Chat launcher (stubbed osascript/claude, nothing real opens) =='
check_fails 'launch_run rejects missing project dir' env PATH="$SAFE_PATH" sh "$REPO/chat/launch_run.sh" "$TMPROOT/nope" 'x'
check_fails 'launch_run rejects double-quoted prompt' env PATH="$SAFE_PATH" sh "$REPO/chat/launch_run.sh" "$TMPROOT" 'bad " prompt'
check_fails 'launch_run wants exactly 2 args' env PATH="$SAFE_PATH" sh "$REPO/chat/launch_run.sh" "$TMPROOT"
if [ "$(uname -s)" = Darwin ]; then
  : >"$STUB_LOG"
  check 'launch_run happy path (stubbed)' env PATH="$SAFE_PATH" sh "$REPO/chat/launch_run.sh" "$TMPROOT" '/loop /albert smoke goal'
  check_grep 'osascript received the project path' "$TMPROOT" "$STUB_LOG"
  check_grep 'osascript received the prompt' '/loop /albert smoke goal' "$STUB_LOG"
fi
if command -v python3.12 >/dev/null 2>&1; then
  say '  skip setup.sh missing-python test: python3.12 present on this box'
else
  check_fails 'chat setup.sh fails clearly without python3.12' sh "$REPO/chat/setup.sh"
fi

say ''
say '== 8. Supervisor fast-fail cutoff (run-forever gives up, not spins) =='
START=$(date +%s)
env ALBERT_NODE_PATH=/usr/bin/false sh "$CONSOLE_DIR/run-forever.sh" >/dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$RC" -eq 1 ] && [ "$ELAPSED" -lt 60 ]; then
  ok "run-forever gave up after 5 fast failures in ${ELAPSED}s"
else
  bad "run-forever rc=$RC elapsed=${ELAPSED}s (expected rc=1 under 60s)"
fi

say ''
say '== 9. Uninstaller in isolated HOME =='
mkdir -p "$TMPROOT/dirty2" && touch "$TMPROOT/dirty2/keep.txt"
check_fails 'uninstall refuses unowned console dir' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/uninstall.sh" --console-dir "$TMPROOT/dirty2"
check 'unowned dir survives refusal' test -f "$TMPROOT/dirty2/keep.txt"
check 'uninstall.sh full removal' env HOME="$FAKE_HOME" PATH="$SAFE_PATH" sh "$REPO/uninstall.sh"
check_fails 'skill removed' test -e "$CLAUDE_DIR/skills/albert"
check_fails 'workflow removed' test -e "$CLAUDE_DIR/workflows/chunk-exec.js"
check_fails 'emit helper removed' test -e "$CLAUDE_DIR/agent-runs/_emit.mjs"
check_fails 'loop agents removed' test -e "$CLAUDE_DIR/agents/loop-worker.md"
check 'generic helper agents preserved' test -f "$CLAUDE_DIR/agents/code-reviewer.md"
check 'run history preserved' test -f "$STORE/$RUN/events.jsonl"
check_fails 'console dir removed' test -e "$CONSOLE_DIR"
if [ "$(uname -s)" = Darwin ]; then
  check_fails 'launchd plist removed' test -e "$PLIST"
  check_grep 'stubbed launchctl booted out service' 'launchctl bootout' "$STUB_LOG"
fi

say ''
say '== 10. No residue on the real system =='
REAL_CLAUDE=${REAL_HOME:-$HOME}/.claude
check_fails 'real ~/.claude has no albert skill' test -e "$REAL_CLAUDE/skills/albert"
check_fails 'real LaunchAgents has no albert plist' test -e "${REAL_HOME:-$HOME}/Library/LaunchAgents/com.sdraugel.albert.console.plist"
if lsof -nP -tiTCP:"$TEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  bad "something still listens on $TEST_PORT"
else
  ok "test port $TEST_PORT is free again"
fi

say ''
say "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
