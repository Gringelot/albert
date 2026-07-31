# Albert on macOS — Test Strategy, Results, and Your Own Test Plan

<!-- NOTE: All testing below was performed with ZERO changes to the host system: every
     stateful check runs against a throwaway mktemp HOME with launchctl/osascript/claude
     stubbed onto PATH, servers bind test ports (4497/4499) and are killed afterward, and
     a final sweep asserts no residue on the real machine. -->

## Strategy

Three layers, each independent of the last:

1. **Deterministic smoke suite** — [`tools/test-unix.sh`](../../tools/test-unix.sh), one
   POSIX script implementing the verification list from the
   [unix-parity design doc](../superpowers/specs/2026-07-28-unix-parity-design.md).
   Isolated by construction (fake HOME, PATH stubs, test port). Rerunnable anytime, ~40s.
2. **Live demo validation** — boot the console against synthetic demo data and verify the
   HTTP surface (UI, four JSON APIs, SSE stream, loopback-only binding) plus the rendered
   UI in a real browser.
3. **Independent multi-agent review** — three fresh-context agents with no stake in the
   implementation: a code reviewer over the full diff, a security auditor over the
   install/launch surface, and a functional validator that re-ran layers 1–2 from a clean
   shell. Findings were verified before being acted on.

What each smoke-suite section proves:

| # | Section | Proves |
|---|---|---|
| 1 | Static checks | Every `.sh` parses under macOS `/bin/sh` (bash 3.2 POSIX); every `.mjs`/`.js` parses under node; every chat `.py` compiles |
| 2 | Renderer output | Installed SKILL/workflow copies contain no `{{tokens}}`, no backslash paths, no `powershell`/`init.ps1` remnants; the sh grant is narrow (no blanket `Bash(sh *)`); control characters in a service value are refused with no file written; rendered workflow still parses |
| 3 | Installer | Full install into isolated HOME lands skill, 11 loop agents, helpers, workflow, run store, console (+ ownership marker, exec bits); launchd plist has correct `--store`/`--projects` (regression guard for the transcripts-root fix) |
| 4 | Validation rejections | Bad port, non-empty unowned console dir, `/`, `..` paths all refused; refusal touches nothing |
| 5 | Run-store helpers | `_emit.mjs` appends valid events; `_inbox.mjs` write → list → reply round-trip archives the message and emits `chat.msg`/`chat.reply` |
| 6 | Live console | Server boots on demo data; `/`, `/api/roster`, `/api/runs`, `/api/sessions`, `/api/usage` return 200/valid JSON; `/events` is SSE; socket bound to 127.0.0.1 only |
| 7 | Chat launcher | `launch_run.sh` rejects bad input; happy path passes project+prompt through osascript argv (stubbed — nothing opens); `setup.sh` fails cleanly without python3.12 |
| 8 | Supervisor | `run-forever.sh` gives up after 5 fast failures (~20s) instead of spinning |
| 9 | Uninstaller | Refuses unowned dirs; full removal deletes exactly the owned set; preserves generic helper agents and run history |
| 10 | Real system unchanged | Real `~/.claude/skills/albert` and the real launchd plist are in the same state as before the run (snapshot-compared, so it stays valid after you install), and the test port is free again |

## Results — 2026-07-31

Environment: macOS 26.5.2 (arm64), node v26.5.0, `/bin/sh` = bash 3.2.57 POSIX mode,
claude CLI 2.1.220 (native binary), no python3.12 present.

**Final state: 116 checks passing, 0 failing**, stable across consecutive runs and from any
working directory. Nothing was installed on the host; section 10 asserts the real
`~/.claude` and `~/Library/LaunchAgents` are byte-for-byte unchanged by the run.

Fifteen defects were found and fixed across five feature branches. The ones that would
have bitten you on this Mac:

| Severity | Defect | Fix |
|---|---|---|
| High | The renderer widened the Windows grant `Bash(powershell -File *)` into `Bash(sh *)`, pre-approving `sh -c '<anything>'` unprompted — in a harness that runs unattended over research output, repo contents, and the chat inbox | Grants only the run's `init.sh`, bare and quoted |
| High | Installed consoles tailed the wrong directory, so Sessions/Fleet/Comms stayed silently empty | `--projects` now points at the transcripts root |
| Major | `console/stop.sh` didn't actually stop the console — `bootout` unloads only the running domain, and `RunAtLoad` revived it at next login | Added `launchctl disable`, with `enable` in install/restart |
| Major | `--port N` configured the service but the lifecycle scripts stayed on 4400, so `restart.sh` reported failure for a healthy console and `stop.sh` left it running | Port stamped into the installed scripts |
| Major | `restart.sh` reported `FAILED to come up` on a successful restart whenever `lsof` was missing (its `die` ran inside a command substitution and only killed the subshell) | `lsof` checked once at top level |
| Medium | The installed run-store README still named `init.ps1` and taught PowerShell quoting, contradicting the rendered skill beside it | Targeted render of the two Windows-specific parts |
| Medium | Path arguments were validated *before* being made absolute, so a relative `--console-dir` from a hostile cwd bypassed validation | Validate after absolutizing; `XDG_CONFIG_HOME` too |
| Medium | Supervisors were matched with `pgrep -f`, which treats the path as a regex — a console dir with regex metacharacters could kill unrelated processes | Literal matching via `ps` |

Linux-only, fixed while here: the systemd unit quoted `WorkingDirectory=`, which that
setting's parser does not unquote — the unit failed to load and **every Linux install
aborted** partway through. Also a `chat` run launch that blocked past the backend's
60-second timeout and got killed along with the run it had just started.

Two suite bugs are worth calling out because they mattered: the residue checks asserted
the real `~/.claude` was *empty*, which would false-fail for you the moment you actually
install; and an orphaned server from a broken run was answering every HTTP check while the
suite's own server exited on `EADDRINUSE` — a broken run reading as green. Both fixed; the
suite now refuses to start when the test port is occupied.

### Independent multi-agent validation

Three fresh-context agents reviewed the work with no stake in it. Findings were verified
against the code before being acted on; every confirmed one is fixed above.

- **Code review** (full diff): 1 blocker, 3 major, 9 minor. Verified clean: renderer token
  rewriting across the skill, all 17 agent files and the workflow (zero residual `\`,
  `{{`, `powershell`, `.ps1`); launchd plist passes `plutil -lint` and handles the space in
  `Application Support`; POSIX-sh conformance under bash 3.2 with no bashisms; install ↔
  uninstall symmetry; file modes executable straight from `git clone`.
- **Security audit**: 1 high, 3 medium, 5 low, 5 informational. Verified clean: the
  AppleScript launcher is injection-safe (quoted heredoc, `quoted form of` tested against
  `'`, `` ` ``, `$(…)`, `;`, newlines); the plist rendering resists a hostile console dir;
  everything binds `127.0.0.1` with the chat's Origin guard untouched; the Unix scripts
  make no network calls at all.
- **Functional validation**: booted the demo console and drove it in a real browser. All
  views render (graph with the full roster, fleet, sessions listing all four demo runs),
  the browser console is completely clean, and `/api/roster`, `/api/runs`, `/api/sessions`
  match the UI exactly. One cosmetic finding: at 1600×1000 the activity overlay clips the
  CLEANUP node label in the graph view.

## Known limits of this test pass (by design — nothing was installed for real)

- Real launchd registration was exercised only against a **stubbed** `launchctl`; the
  plist content is asserted, but a real `bootstrap`/`kickstart` cycle awaits your install.
- Chat runtime (Chainlit UI, concierge, reply watcher) was **not** booted — needs
  `python3.12`, which isn't on this machine. Static compile checks + launcher tests only.
- No real `/albert` run was executed (that requires installing the skill into the real
  `~/.claude` and letting agents edit a repo).
- Linux paths (systemd unit, xdg dirs) are rendered and syntax-checked, not booted.
- Section 9 (uninstaller) skips itself while a chat supervisor from this checkout is
  running — `uninstall.sh` matches supervisors by repo path, and the suite will not stop
  a live one of yours.
- `uninstall.sh` kills whatever *you* have listening on the ports it is given, and it
  defaults to 4400/4401. If you installed with `--port N`, pass the same `--port N` when
  uninstalling.

## Your own testing — commands and steps

Ordered least → most invasive. Stop at any tier.

### Tier 0 — no install, no system changes (safe anytime)

```sh
cd ~/Documents/code/projects/github/personal/albert
git checkout macos-cross-platform-support
sh tools/test-unix.sh              # expect: "=== 116 passed, 0 failed ===", ~60s
./install.sh --demo-only           # console on http://localhost:4400 with fake data; Ctrl+C to stop
```

In the demo, check: graph view animates the roster; Sessions lists acme-store,
widgetworks-ui, demo-blog, pixel-forge; Comms streams rows.

### Tier 1 — real install, no always-on service

<!-- NOTE: your ~/.claude symlinks into ~/Documents/code/.claude — installed files will
     show up as untracked in the code workspace repo. Decide: commit them or gitignore
     skills/albert/, agents/loop-*.md, workflows/chunk-exec.js, agent-runs/. -->

```sh
./install.sh --no-task             # harness + console, NO launchd service
node ~/Library/Application\ Support/AlbertConsole/server.mjs   # foreground console
```

Open http://localhost:4400 — **your real Claude Code sessions** should appear in
Sessions/Fleet within seconds of using Claude Code anywhere. That view being populated is
the proof the `--projects` fix holds on a real install. Ctrl+C stops it.

### Tier 2 — always-on service

```sh
./install.sh                       # re-run over Tier 1; adds + starts the launchd agent
launchctl print gui/$(id -u)/com.sdraugel.albert.console | head -5
```

Reboot-or-relogin later and confirm http://localhost:4400 is just there.

### Tier 3 — chat

```sh
brew install python@3.12           # one-time; chat pins 3.12 for Chainlit
./chat/setup.sh
./chat/start.sh                    # http://127.0.0.1:4401 + CHAT button in the console
```

Ask the concierge "what runs exist?" (reads the store, no run needed). Then test run
launch: expect a macOS Automation permission prompt the first time, then a new
Terminal.app window running the goal.

### Tier 4 — first real /albert run

Use a repo you can reset. From a Claude Code session in that repo:

```
/albert "Add a --version flag and a test for it"
```

Watch http://localhost:4400. Verify: tasks.json appears under
`~/.claude/agent-runs/<run-id>/`, producer/verifier events stream in Comms, and the PR (or
branch) lands in the target repo with `merge_policy` respected.

### Tear down

```sh
./uninstall.sh                     # removes service, console, harness (keeps run history)
```
