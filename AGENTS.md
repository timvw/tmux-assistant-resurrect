# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
OpenCode, Codex CLI) across tmux restarts. It hooks into tmux-resurrect to save
session IDs and restore them automatically.

## Detection approach

Agent detection is done via direct process inspection: the save script takes a
`ps` snapshot and matches child processes of tmux pane shells against known
assistant binary names (`claude`, `opencode`, `codex`).

Session ID extraction uses tool-native mechanisms (state files, process args,
JSONL lookup) -- this is infrastructure plumbing, not heuristic classification.

## Architecture

- `hooks/` -- Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/` -- tmux-resurrect post-save/post-restore hooks (collect and replay session IDs)
- `config/` -- tmux configuration snippet (TPM + resurrect + continuum settings)
- `docs/` -- Design principles documentation
- `justfile` -- Installation, management, and debugging recipes

## Key conventions

- All scripts use `set -euo pipefail`
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `$XDG_RUNTIME_DIR` or `$TMPDIR` + `/tmux-assistant-resurrect`)
- Log files go to `~/.tmux/resurrect/assistant-{save,restore}.log`
- Process inspection uses `ps -eo pid=,ppid=` (not `pgrep -P` -- unreliable on macOS)
- Agent detection matches binary names via `case` patterns in `detect_tool()`
- Session IDs are extracted via native tool mechanisms (infrastructure plumbing)

## Testing

```bash
# Run a manual save and inspect the output
just save
cat ~/.tmux/resurrect/assistant-sessions.json | jq .

# Check installation status
just status

# Preview what restore would do (without executing)
jq -r '.sessions[] | "\(.tool) in \(.pane): \(.session_id)"' \
    ~/.tmux/resurrect/assistant-sessions.json

# Check logs
cat ~/.tmux/resurrect/assistant-save.log
cat ~/.tmux/resurrect/assistant-restore.log
```

## Adding a new assistant

1. Add a `case` pattern in `detect_tool()` in `scripts/save-assistant-sessions.sh`
2. Add a `get_<tool>_session` function for session ID extraction
3. Add a restore command in `scripts/restore-assistant-sessions.sh`
4. Optionally add a hook/plugin in `hooks/` if the tool doesn't expose session IDs externally
5. Update install/uninstall recipes in `justfile` if a new hook was added

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add support for <tool>`
- `fix: handle <edge case>`
- `docs: update README`
