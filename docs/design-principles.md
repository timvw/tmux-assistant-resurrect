# Design Principles

## Direct process detection

Agent detection uses direct process inspection rather than LLM-based
classification or screen content analysis. The save script:

1. Takes a single `ps -eo pid=,ppid=,args=` snapshot (efficient, no per-pane calls)
2. For each tmux pane, finds direct child processes of the pane's shell
3. Matches binary names via `case` patterns (`*/claude`, `*/opencode`, `*/codex`)
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

## Session ID extraction

Session IDs are extracted through tool-native mechanisms -- infrastructure
plumbing, not interpretation. Each tool has a primary method and a fallback
to address the chicken-and-egg problem (session IDs may be in process args
before hooks/plugins have fired):

- **Claude Code**: `SessionStart` hook state file keyed by Claude's PID
  (primary); `--resume <id>` in process args (fallback -- note: Claude
  overwrites its process title, so this only works if args are still visible)
- **OpenCode**: `-s` / `--session` flag in process args (fast path); plugin
  state file (fallback for runtime session switches); SQLite database query
  at `~/.local/share/opencode/opencode.db` matching the pane's cwd (version-
  resilient fallback when the plugin hasn't fired)
- **Codex CLI**: PID lookup in `~/.codex/session-tags.jsonl` (primary);
  `resume <id>` in process args (fallback)

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
- **Codex CLI** runs via Node.js and preserves its full command line in `ps`,
  so `codex resume <id>` is always visible.
- **OpenCode** is a native Go binary (distributed via npm as `opencode-ai`
  or installed via `opencode upgrade`). Like Claude, the Go binary overwrites
  its process title, so `-s <id>` is NOT visible in `ps`. The plugin state
  file and SQLite database fallback are the reliable sources of session IDs.

## macOS considerations

- `pgrep -P` is unreliable on macOS (silently misses children). Always use
  `ps -eo pid=,ppid=` with awk filtering instead.
- tmux 3.4 converts tab characters to underscores in `-F` format output. The
  save script uses pipe `|` as the delimiter instead.
