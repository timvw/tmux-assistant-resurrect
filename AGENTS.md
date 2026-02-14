# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
OpenCode, Codex CLI) across tmux restarts. It hooks into tmux-resurrect to save
session IDs and restore them automatically.

## Architecture

- `hooks/` — Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/` — tmux-resurrect post-save/post-restore hooks (collect and replay session IDs)
- `config/` — tmux configuration snippet (TPM + resurrect + continuum settings)
- `justfile` — Installation, management, and debugging recipes

## Key conventions

- All scripts use `set -euo pipefail`
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `/tmp/tmux-assistant-resurrect/`)
- Log files go to `~/.tmux/resurrect/assistant-{save,restore}.log`
- Process detection uses `ps -eo pid=,ppid=` (not `pgrep -P` — unreliable on macOS)
- Session IDs are extracted via native tool mechanisms, never heuristics

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

1. Add a detection case in `scripts/save-assistant-sessions.sh` (`detect_tool` function)
2. Add a session ID extraction function (`get_<tool>_session`)
3. Add a restore command in `scripts/restore-assistant-sessions.sh`
4. Optionally add a hook/plugin in `hooks/` if the tool doesn't expose session IDs externally
5. Update install/uninstall recipes in `justfile` if a new hook was added

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add support for <tool>`
- `fix: handle <edge case>`
- `docs: update README`
