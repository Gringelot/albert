# Unix parity design

## Goal

Add macOS and Ubuntu support as a direct, side-by-side port of the existing
Windows installation, Console lifecycle, and Albert Chat lifecycle scripts.

The Unix scripts must remain visibly parallel to their Windows counterparts.
Preserve the existing section order, comments, messages, retry limits, and
control flow wherever the operating systems allow it. Change only scripting
syntax, path syntax, executable names, and operating-system primitives.

## Porting contract

- Keep every existing `.ps1`, `.cmd`, and `.vbs` file unchanged.
- Do not introduce a `platform/` directory.
- Do not create a shared lifecycle framework or a new service-management
  command.
- Add Unix scripts beside the Windows scripts they parallel.
- Use POSIX `sh`, not Bash-specific syntax.
- Never require `sudo` or install a system-wide service.
- Preserve the Console and Chat ports, loopback binding, retry behavior, and
  security boundaries.
- Accept that `install.ps1` will copy inert Console `.sh` files into the Windows
  Console installation because it already copies every file under `console/`.

## File mapping

| Existing Windows file | New Unix counterpart |
|---|---|
| `install.ps1` | `install.sh` |
| `uninstall.ps1` | `uninstall.sh` |
| `console/start.cmd` | `console/start.sh` |
| `console/restart.cmd` | `console/restart.sh` |
| `console/stop.cmd` | `console/stop.sh` |
| `console/run-hidden.vbs` | `console/run-hidden.sh` |
| `console/run-forever.vbs` | `console/run-forever.sh` |
| `chat/setup.cmd` | `chat/setup.sh` |
| `chat/start.cmd` | `chat/start.sh` |
| `chat/stop.cmd` | `chat/stop.sh` |
| `chat/run-forever.vbs` | `chat/run-forever.sh` |
| `chat/launch_run.ps1` | `chat/launch_run.sh` |

## Root installer and uninstaller

`install.sh` mirrors the parameters and phases of `install.ps1`:

- Require Node 20 or newer.
- Default the Claude Code directory to `$HOME/.claude`.
- Default the projects directory to the parent of the Albert repository.
- Install the `/albert` skill, loop agents, generic helper agents, workflow,
  run-store helpers, and run-store README.
- Preserve existing generic helper agents just as the Windows installer does.
- Leave existing run data untouched.
- Install the Console unless `--no-console` is supplied.
- Register an always-on per-user Console service unless `--no-task` is supplied.
- Support `--demo-only` without installing Albert.
- Preserve the Windows installer's informational and success-message structure.

The Console installation directory follows the native per-user convention:

- macOS: `$HOME/Library/Application Support/AlbertConsole`
- Ubuntu: `${XDG_DATA_HOME:-$HOME/.local/share}/albert-console`

The per-user service mechanism is:

- macOS: launchd agent `com.sdraugel.albert.console`
- Ubuntu: systemd user unit `albert-console.service`

The service runs `console/run-hidden.sh`, which waits for and propagates the
Console server's exit status as the direct Unix counterpart of
`run-hidden.vbs`.

`uninstall.sh` mirrors `uninstall.ps1`:

- Stop and unregister the corresponding per-user Console service.
- Stop any matching `run-forever.sh` supervisor before stopping the server.
- Remove only the configured, Albert-owned Console directory.
- Remove the Albert skill, loop agents, workflow, and run-store helper files.
- Preserve run history and pre-existing generic helper agents.
- Never remove an ambiguous or unmarked Console directory recursively.

A small Node renderer may be used by `install.sh` because Node is already a
required dependency. It performs the same install-time token replacement as
the PowerShell installer and translates installed harness copies from Windows
paths and `init.ps1` language to Unix paths and `init.sh` language. Canonical
harness templates remain unchanged for Windows.

## Console lifecycle scripts

`console/start.sh`:

- Opens `http://127.0.0.1:4400/` after the same short delay as `start.cmd`.
- Runs `server.mjs` in the foreground.
- Uses `open` on macOS and `xdg-open` on Ubuntu.

`console/restart.sh`:

- Restarts the registered launchd or systemd user service.
- Handles a stale same-user listener on port 4400 before restarting, matching
  the purpose of `restart.cmd`.
- Prints the resulting process/listener state.

`console/stop.sh`:

- Stops or disables the per-user service first.
- Stops a matching `run-forever.sh` supervisor next.
- Stops the same-user process listening on port 4400 last.
- Does not kill an unrelated or differently owned process.

`console/run-hidden.sh`:

- Runs the Console without spawning another process layer.
- Waits for the server and propagates its exit status.
- Resolves `server.mjs` beside itself so the installed copy is self-contained.

`console/run-forever.sh`:

- Runs the Console without a visible terminal dependency.
- Relaunches it five seconds after an ordinary exit.
- Gives up after five consecutive exits that occur in under ten seconds.
- Resets the fast-failure count after a longer-lived run.

## Albert Chat lifecycle scripts

Chat remains optional and repository-local. The root installer does not create
its virtual environment and does not register Chat for autostart.

`chat/setup.sh`:

- Requires a `python3.12` executable.
- Creates `chat/.venv` only when it is missing.
- Verifies that the environment is Python 3.12.
- Installs `chat/requirements.txt`.
- Preserves the setup script's existing messages and failure behavior.

`chat/start.sh`:

- Requires `chat/.venv/bin/python`.
- Opens `http://127.0.0.1:4401/` after the same short delay as `start.cmd`.
- Runs `uvicorn server:app --host 127.0.0.1 --port 4401` in the foreground.
- Continues to use `server.py`; it must not bypass the existing Origin guard.

`chat/stop.sh`:

- Stops a matching `run-forever.sh` supervisor first.
- Stops the same-user process listening on port 4401 second.
- Does not kill an unrelated or differently owned process.

`chat/run-forever.sh`:

- Requires `chat/.venv/bin/python`.
- Runs the same guarded Uvicorn command as `start.sh`.
- Preserves the five-second restart delay, ten-second fast-failure threshold,
  and five-failure cutoff from `run-forever.vbs`.

`chat/launch_run.sh`:

- Accepts the project directory and prompt as separate arguments.
- Validates the project directory and requires the Claude CLI on `PATH`.
- Opens a separate, visible terminal that survives the Chat process.
- Uses the built-in Terminal application on macOS.
- Uses Ubuntu's `x-terminal-emulator`.
- Preserves the current restriction that the prompt must not contain double
  quotes.
- Passes paths and prompts without allowing shell metacharacters to become
  executable syntax.
- Fails clearly when no supported graphical terminal is available. Headless
  run launching is outside this migration.

Optional always-on Chat setup remains documentation-only, matching Windows:
document how to point a user launchd agent or systemd user unit at
`chat/run-forever.sh`. Do not add `chat/service.sh` or automatically register
Chat from `chat/setup.sh`.

## Shared-code changes

Keep shared changes narrow:

- `chat/config.py` exposes the adjacent PowerShell and shell launcher paths.
- `chat/albert_tools.py` keeps the current Windows PowerShell invocation and
  uses `sh chat/launch_run.sh` on non-Windows systems.
- The current run-id, project-root, active-run, and goal validation remains in
  place.
- The Console's Chat-offline instructions show both the Windows and Unix setup
  and start commands.

No other Chat Python behavior changes. The Chainlit application, concierge,
read-only tool gate, inbox protocol, reply watcher, and Origin guard remain
unchanged.

## Documentation

Update documentation additively:

- Keep all existing Windows commands and paths valid.
- Add macOS and Ubuntu installation, uninstallation, Console lifecycle, and
  Chat lifecycle commands.
- Document `$HOME/.claude` as the shared harness target.
- Document the native Console install directory and per-user service manager
  for each Unix platform.
- State that Chat is optional and separately enabled on every platform.
- Document the graphical-terminal requirement for launching a run from Chat.
- Add the isolated Unix test command to `CONTRIBUTING.md` without replacing
  the existing Windows verification guidance.

## Error handling and safety

- Reject unsupported operating systems with an actionable message.
- Reject invalid ports and unsafe or ambiguous removal targets.
- Treat missing launchd, systemd user sessions, Python 3.12, Node, browser
  openers, and graphical terminal launchers as explicit conditions rather than
  silently changing behavior.
- Allow `--no-task` when a per-user service manager is unavailable.
- Keep all services bound to `127.0.0.1`.
- Keep service files and state under the current user.
- Do not follow symlinks or recursively remove unowned Console directories.
- Stop supervisors before servers so they cannot immediately relaunch.

## Verification

Automated verification must cover:

- `sh -n` for every new shell script.
- `node --check` for the install renderer.
- Python compilation for modified Chat Python files.
- An isolated temporary `HOME` for installer and uninstaller tests.
- Stubbed `uname`, `launchctl`, `systemctl`, browser opener, Python, Claude CLI,
  and terminal launcher commands so tests never touch real services or open
  applications.
- macOS and Ubuntu installer defaults, overrides, `--no-console`, `--no-task`,
  and `--demo-only`.
- Generated launchd and systemd definitions.
- Owned-directory removal and refusal to remove unowned directories.
- Console and Chat foreground command construction.
- Console and Chat supervisor restart and fast-failure behavior.
- Windows and Unix `start_albert_run` command selection.
- Argument handling for spaces and shell metacharacters.
- The Chat Origin guard remains on the Unix start path.

The Windows immutability gate is:

```sh
git diff --exit-code HEAD -- '*.ps1' '*.cmd' '*.vbs'
```

The implementation is not complete unless that command is clean and the
existing Windows commands in the documentation remain valid.

## Out of scope

- Moving files into a `platform/` directory.
- Refactoring Windows launchers.
- A shared cross-platform lifecycle library.
- Automatically installing or registering Albert Chat.
- Supporting non-systemd Linux distributions.
- Supporting arbitrary Linux terminal emulators.
- Supporting headless Chat-initiated run launching.
- Changing ports, security boundaries, run-store formats, or Chat behavior.
