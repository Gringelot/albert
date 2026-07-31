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
| 2 | Renderer output | Installed SKILL/workflow copies contain no `{{tokens}}`, no backslash paths, no `powershell`/`init.ps1` remnants; rendered workflow still parses |
| 3 | Installer | Full install into isolated HOME lands skill, 11 loop agents, helpers, workflow, run store, console (+ ownership marker, exec bits); launchd plist has correct `--store`/`--projects` (regression guard for the transcripts-root fix) |
| 4 | Validation rejections | Bad port, non-empty unowned console dir, `/`, `..` paths all refused; refusal touches nothing |
| 5 | Run-store helpers | `_emit.mjs` appends valid events; `_inbox.mjs` write → list → reply round-trip archives the message and emits `chat.msg`/`chat.reply` |
| 6 | Live console | Server boots on demo data; `/`, `/api/roster`, `/api/runs`, `/api/sessions`, `/api/usage` return 200/valid JSON; `/events` is SSE; socket bound to 127.0.0.1 only |
| 7 | Chat launcher | `launch_run.sh` rejects bad input; happy path passes project+prompt through osascript argv (stubbed — nothing opens); `setup.sh` fails cleanly without python3.12 |
| 8 | Supervisor | `run-forever.sh` gives up after 5 fast failures (~20s) instead of spinning |
| 9 | Uninstaller | Refuses unowned dirs; full removal deletes exactly the owned set; preserves generic helper agents and run history |
| 10 | No residue | Real `~/.claude`, real LaunchAgents, and the test port are untouched/free afterward |

## Results — 2026-07-31

Environment: macOS 26.5.2 (arm64), node v26.5.0, `/bin/sh` = bash 3.2.57 POSIX mode,
claude CLI 2.1.220 (native binary), no python3.12 present.

- **Smoke suite: 105 passed, 0 failed** (`sh tools/test-unix.sh`).
- First run surfaced one test-harness bug (macOS `$TMPDIR` trailing slash produced `//`
  paths, correctly rejected by the installer's own path validation) — fixed in the suite;
  the rejection is evidence the installer safety checks work.
- One product bug found by review and fixed on this branch:
  `install.sh` passed the code-projects dir as the service's `--projects` argument, where
  `server.mjs` expects the Claude transcripts root — installed consoles would show empty
  Sessions/Fleet/Comms. Fix: `fix(install): point console service --projects at the
  transcripts root`, with a regression guard in suite section 3.
- Multi-agent validation: see below.

### Multi-agent validation results

<!-- Filled from the three independent agent reports; see the branch worklog. -->
_Pending — this section is completed in the same commit once all three agent reports are in._

## Known limits of this test pass (by design — nothing was installed for real)

- Real launchd registration was exercised only against a **stubbed** `launchctl`; the
  plist content is asserted, but a real `bootstrap`/`kickstart` cycle awaits your install.
- Chat runtime (Chainlit UI, concierge, reply watcher) was **not** booted — needs
  `python3.12`, which isn't on this machine. Static compile checks + launcher tests only.
- No real `/albert` run was executed (that requires installing the skill into the real
  `~/.claude` and letting agents edit a repo).
- Linux paths (systemd unit, xdg dirs) are rendered and syntax-checked, not booted.

## Your own testing — commands and steps

Ordered least → most invasive. Stop at any tier.

### Tier 0 — no install, no system changes (safe anytime)

```sh
cd ~/Documents/code/projects/github/personal/albert
git checkout macos-cross-platform-support
sh tools/test-unix.sh              # expect: "=== 105 passed, 0 failed ==="
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
