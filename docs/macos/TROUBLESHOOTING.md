# Albert on macOS — Troubleshooting

Symptom-first. Every fix here is safe to run as-is.

## Console loads but Sessions / Fleet / Comms are empty

The service is tailing the wrong transcripts root. Check the plist:

```sh
grep -A1 -- '--projects' ~/Library/LaunchAgents/com.sdraugel.albert.console.plist
```

The value after `--projects` must be `$HOME/.claude/projects` (Claude Code's transcript
store), **not** your code-projects folder. Installs made from this branch are correct;
an install from the original contributor zip has the bug — re-run `./install.sh` to fix,
then `launchctl kickstart -k gui/$(id -u)/com.sdraugel.albert.console`.

Also confirm transcripts exist at all: `ls ~/.claude/projects/` — the console can only
show sessions Claude Code has actually written there.

## Nothing at http://localhost:4400

```sh
launchctl print gui/$(id -u)/com.sdraugel.albert.console | head -20   # is it loaded/running?
tail -50 ~/Library/Application\ Support/AlbertConsole/albert-console-error.log
lsof -nP -iTCP:4400 -sTCP:LISTEN                                      # who owns the port?
```

- **Service not loaded**: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sdraugel.albert.console.plist`
- **Port owned by something else**: install with `./install.sh --port 4402` (any free port).
- **`node` errors in the log after a node upgrade**: the plist pins the node path from
  install time; re-run `./install.sh` to re-pin.

## The service keeps restarting / burns CPU

`launchd` KeepAlive relaunches the server on every exit. Find the crash first:

```sh
tail -100 ~/Library/Application\ Support/AlbertConsole/albert-console-error.log
```

Stop the loop while you investigate: `launchctl bootout gui/$(id -u)/com.sdraugel.albert.console`.
The standalone supervisor (`run-forever.sh`) does NOT have this failure mode — it gives up
after five fast exits by design.

## `install.sh` refuses: "--console-dir is non-empty and is not an Albert Console directory"

Ownership safety: Albert only writes into a directory it created (marked with
`.albert-console-owner`) or an empty one. Point `--console-dir` somewhere empty, or clear
the directory yourself if you're sure. Same rule on uninstall — it will never `rm -rf` a
directory it doesn't own.

## `uninstall.sh` refuses: "paths must not ... repeated slashes"

The path it derived contains `//` (commonly a `$TMPDIR`- or env-derived HOME with a
trailing slash). Pass the directory explicitly without the double slash:
`./uninstall.sh --console-dir "$HOME/Library/Application Support/AlbertConsole"`.

## `chat/setup.sh`: "Python 3.12 not found"

Chat pins Python 3.12 (Chainlit compatibility). On this machine only newer Pythons ship by
default:

```sh
brew install python@3.12
./chat/setup.sh
```

The venv lives entirely in `chat/.venv` — nothing global changes, delete the folder to
undo.

## Chat runs but "start a run" fails

- **"claude CLI not found on PATH"**: the chat process inherited a PATH without
  `~/.local/bin`. Start the chat from a normal login shell (`./chat/start.sh` in Terminal),
  not from a GUI launcher.
- **Nothing opens**: run launching needs a graphical Terminal; it uses AppleScript
  (`osascript`) to open **Terminal.app**. First use may prompt for Automation permission —
  System Settings → Privacy & Security → Automation → allow your terminal to control
  Terminal. Headless launching is intentionally unsupported.
- **"prompt must not contain double quotes"**: by design; rephrase the goal.

## `run-forever.sh` exited on its own

Five consecutive exits in under 10 seconds means something structural: the port is already
served, the install is broken, or (chat) the venv is missing. Fix the underlying error
(check the port with `lsof -nP -iTCP:4400 -sTCP:LISTEN`, run the server once in the
foreground to see the real error), then relaunch.

## Where are the logs?

| Component | Location |
|---|---|
| Console service stdout/stderr | `~/Library/Application Support/AlbertConsole/albert-console.log` / `albert-console-error.log` |
| Run activity (per run) | `~/.claude/agent-runs/<run-id>/events.jsonl`, `iterations/<n>/` |
| Run registry | `~/.claude/agent-runs/index.json` |
| Chat (foreground) | the terminal you started it in |

## Full reset

```sh
./uninstall.sh                       # service + console + harness files
rm -rf ~/.claude/agent-runs          # optional: run history too
rm -rf chat/.venv                    # optional: chat venv
```
