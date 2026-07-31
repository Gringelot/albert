// Renders Unix-safe harness copies and per-user service definitions at install time.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

// Stops with a concise usage error when a renderer invocation is incomplete.
function fail(message) {
  console.error(`render-unix-install: ${message}`);
  process.exit(1);
}

// Writes text after ensuring its destination directory exists.
function writeText(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text, 'utf8');
}

// Control characters cannot be escaped into a safe service-definition value: systemd's
// parser is line-oriented and splits before it dequotes, so an embedded newline ends the
// directive and the rest becomes attacker-chosen configuration. Refuse instead.
function assertNoControlChars(value, what) {
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001F\u007F]/.test(String(value))) fail(`${what} must not contain control characters`);
  return String(value);
}

// Escapes text for XML character data and attribute values.
function xml(value) {
  assertNoControlChars(value, 'plist value');
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

// Quotes a systemd value so spaces and specifier characters remain literal.
function systemd(value) {
  assertNoControlChars(value, 'systemd unit value');
  return `"${String(value).replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('%', '%%').replaceAll('$', () => '$$')}"`;
}

// Quotes one POSIX shell argument, including embedded single quotes.
function shell(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

// Rewrites the Windows-oriented workflow paths without changing its source template.
function renderWorkflow(source, claudeDir) {
  const store = join(claudeDir, 'agent-runs');
  const emit = join(store, '_emit.mjs');
  return source
    .replace("const STORE = '{{CLAUDE_DIR}}\\\\agent-runs';", `const STORE = ${JSON.stringify(store)};`)
    .replace("const EMIT = '{{CLAUDE_DIR}}\\\\agent-runs\\\\_emit.mjs';", `const EMIT = ${JSON.stringify(emit)};`)
    .replace("const RUN_DIR = STORE + '\\\\' + RUN;", "const RUN_DIR = STORE + '/' + RUN;")
    .replaceAll('${RUN_DIR}\\\\tasks.json', '${RUN_DIR}/tasks.json')
    .replaceAll('${RUN_DIR}\\\\project.json', '${RUN_DIR}/project.json')
    .replaceAll('${RUN_DIR}\\\\goal.md', '${RUN_DIR}/goal.md')
    .replaceAll('<repo_parent>\\\\.hx-wt\\\\${RUN}-${CHUNK}-<id>', '<repo_parent>/.hx-wt/${RUN}-${CHUNK}-<id>')
    .replaceAll('.hx-wt\\\\${RUN}-${CHUNK}-', '.hx-wt/${RUN}-${CHUNK}-');
}

// Renders a Markdown harness template with Unix paths and bootstrap instructions.
function renderMarkdown(source, claudeDir, projectsDir, consoleDir) {
  const runStore = join(claudeDir, 'agent-runs');
  const bootstrapScript = join(runStore, '<run-id>', 'init.sh');
  const bootstrapPattern = join(runStore, '*', 'init.sh');
  return source
    // macOS ships no bare `python`, and Debian/Ubuntu need python-is-python3 for one.
    // Without this the harness prompts on every python3 command, which stalls /loop runs.
    .replaceAll('  - Bash(python *)', '  - Bash(python *)\n  - Bash(python3 *)')
    .replaceAll('{{CLAUDE_DIR}}\\agent-runs', runStore)
    .replaceAll('{{CLAUDE_DIR}}', claudeDir)
    .replaceAll('{{PROJECTS_DIR}}', projectsDir)
    .replaceAll('{{CONSOLE_DIR}}', consoleDir)
    .replaceAll('\\', '/')
    .replaceAll('# init.ps1,', '# init.sh,')
    .replaceAll('init.ps1', 'project.json.bootstrap_command')
    // The Windows grant it replaces (`powershell -File <script>`) can only run a script
    // already on disk. A blanket `Bash(sh *)` would additionally pre-approve
    // `sh -c '<anything>'` with no prompt, which matters because this harness runs
    // unattended over untrusted input (research output, repo contents, the chat inbox).
    // Grant only the one sh command the harness actually issues: the run's init.sh.
    // Both forms are listed because bootstrap_command records the path shell-quoted;
    // permission rules are OR'd and matched per compound-command segment.
    .replaceAll(
      '  - Bash(powershell -File *)',
      `  - Bash(sh ${bootstrapPattern})\n  - Bash(sh '${bootstrapPattern}')`,
    )
    .replace(
      'Write `project.json.bootstrap_command` (idempotent env bootstrap for this project) and `progress.json`',
      `Write \`init.sh\` (idempotent env bootstrap for this project), record \`bootstrap_command: "sh ${shell(bootstrapScript)}"\` in \`project.json\` with this run's actual id, and write \`progress.json\`.`,
    );
}

// The run-store README ships next to the rendered SKILL, so it must not keep telling agents
// the bootstrap file is init.ps1 or that PowerShell quoting rules apply. A blanket markdown
// render would corrupt its shell-quoting examples (backslash rewriting), so retarget the two
// Windows-specific parts and leave the rest byte-identical.
const POSIX_QUOTING_SECTION = `### Shell quoting for \`jsonData\`

\`jsonData\` must reach node as literal JSON, quotes included. In a POSIX shell (sh, bash,
zsh), wrap it in single quotes:

\`\`\`sh
node _emit.mjs my-run-2026-07-15 test.ping chief store "ping" '{"k":1}'
\`\`\`

Other arguments containing spaces (typically \`<summary>\`) only need normal quoting.

`;

function renderStoreReadme(source) {
  const start = source.indexOf('### Shell quoting for `jsonData`');
  const end = source.indexOf('## Chat inbox');
  const rewritten = start !== -1 && end !== -1 && end > start
    ? source.slice(0, start) + POSIX_QUOTING_SECTION + source.slice(end)
    : source;
  return rewritten.replaceAll(
    '`init.ps1` - idempotent environment bootstrap for this project.',
    '`init.sh` - idempotent environment bootstrap for this project (its path is recorded in `project.json.bootstrap_command`).',
  );
}

const [command, ...args] = process.argv.slice(2);
if (command === 'template') {
  const [sourceFile, destinationFile, claudeDir, projectsDir, consoleDir, kind] = args;
  if (!sourceFile || !destinationFile || !claudeDir || !projectsDir || !consoleDir || !kind) fail('usage: template <source> <destination> <claude-dir> <projects-dir> <console-dir> <markdown|workflow>');
  const source = readFileSync(sourceFile, 'utf8');
  if (kind === 'markdown') writeText(destinationFile, renderMarkdown(source, claudeDir, projectsDir, consoleDir));
  else if (kind === 'workflow') writeText(destinationFile, renderWorkflow(source, claudeDir));
  else if (kind === 'store-readme') writeText(destinationFile, renderStoreReadme(source));
  else fail(`unknown template kind: ${kind}`);
} else if (command === 'launchd') {
  const [destinationFile, label, nodePath, runnerPath, port, storePath, projectsPath, agentsPath, workingDirectory, outLog, errorLog] = args;
  if (args.length !== 11) fail('usage: launchd <file> <label> <node> <runner> <port> <store> <projects> <agents> <cwd> <out-log> <error-log>');
  const values = ['/bin/sh', runnerPath, '--port', port, '--store', storePath, '--projects', projectsPath, '--agents', agentsPath];
  const argumentsXml = values.map((value) => `    <string>${xml(value)}</string>`).join('\n');
  writeText(destinationFile, `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>Label</key>\n  <string>${xml(label)}</string>\n  <key>ProgramArguments</key>\n  <array>\n${argumentsXml}\n  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n    <key>ALBERT_NODE_PATH</key>\n    <string>${xml(nodePath)}</string>\n  </dict>\n  <key>WorkingDirectory</key>\n  <string>${xml(workingDirectory)}</string>\n  <key>KeepAlive</key>\n  <true/>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>StandardOutPath</key>\n  <string>${xml(outLog)}</string>\n  <key>StandardErrorPath</key>\n  <string>${xml(errorLog)}</string>\n</dict>\n</plist>\n`);
} else if (command === 'systemd') {
  const [destinationFile, nodePath, runnerPath, port, storePath, projectsPath, agentsPath, workingDirectory] = args;
  if (args.length !== 8) fail('usage: systemd <file> <node> <runner> <port> <store> <projects> <agents> <cwd>');
  const execStart = ['/bin/sh', runnerPath, '--port', port, '--store', storePath, '--projects', projectsPath, '--agents', agentsPath].map(systemd).join(' ');
  // WorkingDirectory= is a path-typed setting parsed by config_parse_working_directory,
  // which does NOT unquote. A quoted value is read as a non-absolute path and the unit
  // fails to load ("Exec format error"), aborting every Linux install. ExecStart= and
  // Environment= are EXTRACT_UNQUOTE-parsed, so they keep the quoting. Only % needs
  // escaping here, since specifier expansion runs before quote handling.
  const workingDirectoryValue = assertNoControlChars(workingDirectory, 'systemd unit value').replaceAll('%', '%%');
  writeText(destinationFile, `[Unit]\nDescription=Albert Console\n\n[Service]\nType=simple\nWorkingDirectory=${workingDirectoryValue}\nEnvironment=${systemd(`ALBERT_NODE_PATH=${nodePath}`)}\nExecStart=${execStart}\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n`);
} else {
  fail('usage: template|launchd|systemd ...');
}
