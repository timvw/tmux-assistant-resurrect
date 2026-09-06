# Design Principles

## Direct process detection

Agent detection uses direct process inspection rather than LLM-based
classification or screen content analysis. The save script:

1. Takes a single `ps -eo pid=,ppid=,args=` snapshot (efficient, no per-pane calls)
2. For each tmux pane, finds direct child processes of the pane's shell
3. Matches binary names via `case` patterns (`*/claude`, `*/copilot`,
   `*/opencode`, `*/codex`, `*/pi`, `*/omp`, `*/grok`)
4. Excludes known false positives (e.g., `opencode run ...` LSP subprocesses)

This is simple, fast, and deterministic. No API calls, no LLM costs, no
latency per pane.

## What scripts do

- Capture pane metadata from tmux (PIDs, working directories)
- Detect assistants by matching child process binary names
- Read session ID state files written by tool-native hooks/plugins
- Parse process arguments for session identifiers
- Format and write JSON output
- Send commands to tmux panes via `tmux send-keys`

## Addressing a pane

A pane's saved address is stored as three separate values -- session name,
window index, pane index -- and joined into the familiar `session:window.pane`
form only as a display label and as the key tmux-resurrect's pane-content
archive is named after. The joined form is never given back to tmux as a target.

tmux's target grammar reserves `:` and `.`, and session names may contain both
(tmux 3.7 keeps them; earlier versions rewrote them to `_`). tmux also
prefix-matches session names, so a malformed target does not reliably fail --
it can silently resolve to a different session. `-t '=name'` is not a way out
either, because the grammar splits the string before the exact-match flag
applies.

So restore matches the three parts literally against `tmux list-panes -a -F`
output and works from the pane id (`%N`) it gets back, which every tmux command
accepts verbatim. Pane ids are allocated per tmux server lifetime -- exactly
the boundary a restore crosses -- so they are resolved at restore time and
never written to disk.

## Session ID extraction

Session IDs are extracted through tool-native mechanisms -- infrastructure
plumbing, not interpretation. Each tool has a primary method and a fallback
to address the chicken-and-egg problem (session IDs may be in process args
before hooks/plugins have fired):

- **Claude Code**: `SessionStart` hook state file keyed by Claude's PID
  (primary); `--resume <id>` in process args (fallback -- note: Claude
  overwrites its process title, so this only works if args are still visible);
  newest non-empty transcript under the encoded cwd in
  `~/.claude/projects/` (last resort). The transcript lookup mirrors Claude's
  ASCII-only, UTF-16 cwd encoding and long-path hash. It rejects IDs reserved by
  PID-specific state/argv or already emitted for another pane. It remains
  cwd-scoped rather than PID-specific, so two otherwise unresolved Claude
  processes in one cwd are inherently ambiguous and the newest transcript can
  belong to an abandoned session. Keeping older transcripts eligible is
  deliberate: an untouched `--continue`/`--resume` process may not have written
  anything during its current process lifetime yet.
- **GitHub Copilot CLI**: the live session's own
  `$COPILOT_HOME/session-state/<uuid>/inuse.<pid>.lock` marker, matched by the
  native PID (primary); `--session-id` / `--resume` in process args (fallback,
  for the startup window before the lock exists).
- **OpenCode**: `-s` / `--session` flag in process args (fast path); plugin
  state file (fallback for runtime session switches); SQLite database query
  at `~/.local/share/opencode/opencode.db` matching the pane's cwd (version-
  resilient fallback when the plugin hasn't fired)
- **Codex CLI**: PID lookup in `~/.codex/session-tags.jsonl` (primary);
  `resume <id>` in process args (fallback)
- **Pi**: `--session <id>` in process args (fallback); session header lookup in
  `~/.pi/agent/sessions/--<cwd>--/*.jsonl` (primary for fresh sessions)
- **Oh My Pi**: `--resume <id>` / `-r <id>` in process args (fallback);
  terminal breadcrumb lookup under `$XDG_STATE_HOME/omp` plus session JSONL
  lookup under `$XDG_DATA_HOME/omp` or `~/.omp/agent/sessions` (primary for
  fresh sessions, with `--profile` and `--session-dir` support)
- **Grok**: PID lookup in the `~/.grok/active_sessions.json` registry
  (primary); `-r <uuid>` / `--resume <uuid>` in process args (fallback). grok
  records every live interactive session (including a bare `grok` launched
  with no args) in the registry keyed by PID, so unlike the cwd-scoped
  fallbacks above, two sessions sharing a working directory never collide.
  Resume intentionally drops captured CLI args because grok reloads the
  session's own model/agent/context from disk and its prompt is a positional
  argument that must not be replayed.

## Adding a new assistant

To add support for a new tool:

1. Add a binary name pattern in `detect_tool()` (`case` statement)
2. Add a `get_<tool>_session()` function for session ID extraction
3. Add a restore command in `restore-assistant-sessions.sh`
4. Optionally add a hook/plugin if the tool doesn't expose session IDs externally

## Process title behavior

- **Claude Code** is a Node.js script that overwrites its process title via
  `process.title = 'claude'`. This means `--resume <id>` is NOT visible in
  `ps` output -- the state file from the `SessionStart` hook is the only
  reliable source of session IDs for Claude.
- **GitHub Copilot CLI** uses an npm loader plus a native child process. Both
  match detection, but only the native child owns the session lock. Candidate
  resolution therefore prefers PID-specific lock state before considering
  possibly stale loader argv.
- **Codex CLI** runs via Node.js and preserves its full command line in `ps`,
  so `codex resume <id>` is always visible.
- **OpenCode** is a native Go binary (distributed via npm as `opencode-ai`
  or installed via `opencode upgrade`). Like Claude, the Go binary overwrites
  its process title, so `-s <id>` is NOT visible in `ps`. The plugin state
  file and SQLite database fallback are the reliable sources of session IDs.
- **Pi** stores sessions as JSONL files under `~/.pi/agent/sessions` keyed by
  encoded cwd. Session IDs are in the header line (`type: "session"`, `id`).
  Process args remain a useful fallback when launched with `--session`.
- **Oh My Pi** stores terminal breadcrumbs and JSONL session files under XDG
  directories when present, falling back to `~/.omp`. Session IDs are in the
  JSONL header; process args remain useful after restore via `--resume` / `-r`.

## macOS considerations

- `pgrep -P` is unreliable on macOS (silently misses children). Always use
  `ps -eo pid=,ppid=` with awk filtering instead.
- Copilot's active session is resolved with a plain glob over its own state
  directory — deliberately no `lsof` and no `/proc`, so it behaves identically
  on every platform and costs no fork.
- tmux before 3.7 converts tab characters to underscores in `-F` format output,
  and escapes other control characters differently in each version, so none of
  them is a portable delimiter. The save script uses pipe `|` instead. A `|` can
  legitimately appear in a session name or a path, so each `-F` string ends with
  its one free-form field; the fixed-shape fields ahead of it are peeled off by
  position and the remainder is taken verbatim.

## Windows considerations

- **WSL is the supported Windows story.** It is ordinary Linux: `/proc` is
  present, so process start times, `COPILOT_HOME` from a process environment and
  exact argv from `/proc/<pid>/cmdline` all work exactly as they do natively.
- **Native Windows is not a host for this plugin at all.** tmux has no native
  Win32 port, and this is a tmux-resurrect hook — without tmux there is nothing
  to hook into. The tmux-compatible reimplementations for PowerShell do not run
  tmux plugins either. Copilot's lock lookup being pure filesystem work makes
  the *logic* portable, but that is not the same as the plugin being usable.
- CI runs a `windows-latest` job over the hermetic suites as a portability
  canary. It exists to catch Linux-isms leaking into logic that WSL and MSYS2
  users rely on — it is not a support claim.
