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
plumbing, not interpretation:

- **Claude Code**: `SessionStart` hook writes session ID keyed by PPID
- **OpenCode**: `-s` / `--session` flag in process args (fast path); plugin
  state file (fallback for runtime session switches)
- **Codex CLI**: PID lookup in `~/.codex/session-tags.jsonl`

## Adding a new assistant

To add support for a new tool:

1. Add a binary name pattern in `detect_tool()` (`case` statement)
2. Add a `get_<tool>_session()` function for session ID extraction
3. Add a restore command in `restore-assistant-sessions.sh`
4. Optionally add a hook/plugin if the tool doesn't expose session IDs externally

## macOS considerations

- `pgrep -P` is unreliable on macOS (silently misses children). Always use
  `ps -eo pid=,ppid=` with awk filtering instead.
- Claude Code is a native Mach-O binary (`/opt/homebrew/Caskroom/claude-code/...`),
  not a Node process.
- OpenCode runs under Node (`/opt/homebrew/opt/node/bin/node /opt/homebrew/bin/opencode`).
