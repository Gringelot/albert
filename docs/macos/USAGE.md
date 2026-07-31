# Albert on macOS — Usage

Everything the root [README](../../README.md) says applies; this page is the macOS-specific
operating manual: what gets installed where, how the launchd service behaves, and the
day-to-day commands.

## Prerequisites

| Requirement | Check | Install if missing |
|---|---|---|
| Node 20+ (26 recommended) | `node --version` | `brew install node` |
| Claude Code, signed in | `claude --version` | https://claude.com/claude-code |
| Python 3.12 (optional, chat only) | `python3.12 --version` | `brew install python@3.12` |

`/bin/sh` on macOS is bash 3.2 in POSIX mode; every Albert script targets plain POSIX sh,
so no Homebrew bash is needed.

## Try it without installing anything

```sh
./install.sh --demo-only        # synthetic data, console in the foreground, Ctrl+C to stop
sh tools/test-unix.sh           # full smoke suite in a throwaway HOME, ~40s, no system changes
```

`--demo-only` does not install; it generates demo data under `tools/demo-out/` and serves
the console at http://localhost:4400 until you Ctrl+C.

## Install

```sh
./install.sh                    # harness + console + always-on launchd service
./install.sh --no-task          # harness + console, no service (start it manually)
./install.sh --no-console       # harness only
```

What lands where:

| Piece | Path |
|---|---|
| `/albert` skill (rendered for this machine) | `~/.claude/skills/albert/SKILL.md` |
| Agent roster (11 `loop-*` + generic helpers) | `~/.claude/agents/*.md` |
| Parallel executor workflow | `~/.claude/workflows/chunk-exec.js` |
| Run store + emit/inbox helpers | `~/.claude/agent-runs/` |
| Console app | `~/Library/Application Support/AlbertConsole/` |
| launchd agent (KeepAlive, RunAtLoad) | `~/Library/LaunchAgents/com.sdraugel.albert.console.plist` |
| Console logs | `~/Library/Application Support/AlbertConsole/albert-console*.log` |

<!-- NOTE: If your ~/.claude is a symlink into a dotfiles or workspace repo (as on this
     machine), the skill/agents/workflow files above appear as untracked files in that
     repo after install. Either commit them there deliberately or add them to that repo's
     .gitignore; uninstall.sh removes them cleanly either way. -->

Existing generic helper agents (`code-reviewer`, `security-reviewer`, `performance-reviewer`,
`doc-writer`, `refactor-worker`, `codebase-locator`) are never overwritten — the installer
skips any that already exist and tells you which.

## Run a goal

From a Claude Code session inside any project:

```
/albert "Add pagination to the users API and cover it with tests"        # supervised, one iteration per turn
/loop /albert "Add pagination to the users API and cover it with tests"  # unattended, self-paced
```

Watch it at **http://localhost:4400**.

## Console service management

```sh
launchctl print gui/$(id -u)/com.sdraugel.albert.console   # status
launchctl kickstart -k gui/$(id -u)/com.sdraugel.albert.console  # force restart
launchctl bootout gui/$(id -u)/com.sdraugel.albert.console  # stop until next login
```

Or use the scripts installed with the console (equivalent, plus port cleanup):

```sh
cd ~/Library/Application\ Support/AlbertConsole
./restart.sh      # after editing server.mjs/lib/public — kills the old listener first
./stop.sh         # stop for good: silences launchd, kills supervisor and port owner
./start.sh        # foreground run (when the service is stopped or was never installed)
```

The service definition pins the absolute node path found at install time
(`ALBERT_NODE_PATH` in the plist), so a minimal launchd PATH cannot break it. If you
upgrade/move node (new Homebrew prefix, nvm switch), re-run `./install.sh`.

## Chat (optional)

```sh
./chat/setup.sh    # one-time: builds chat/.venv from python3.12, installs Chainlit + Agent SDK
./chat/start.sh    # serves http://127.0.0.1:4401, opens the browser, foreground
./chat/stop.sh     # kills supervisor (if any) + port owner
```

Then use the **CHAT** button in the console nav rail. Chat-initiated runs open a new
**Terminal.app** window (a graphical terminal is required; the run survives the chat
process). For always-on chat, point a user launchd agent at `chat/run-forever.sh`.

## Uninstall

```sh
./uninstall.sh
```

Removes the launchd agent, the console directory, the skill, the workflow, the emit/inbox
helpers, and the 11 `loop-*` agents. Deliberately left in place: generic helper agents and
`~/.claude/agent-runs/` run history (delete that folder yourself if you want it gone).
