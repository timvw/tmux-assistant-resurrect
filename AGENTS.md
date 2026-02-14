# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
OpenCode, Codex CLI) across tmux restarts. It hooks into tmux-resurrect to save
session IDs and restore them automatically.

## ZFC compliance

This project follows the [Zero False Commands](docs/design-principles.md)
(ZFC) principle: **"Scripts transport. AI decides."**

When working on this project, **never** add code that classifies what is or
isn't an AI coding agent. Agent detection is delegated to
[pane-patrol](https://github.com/timvw/pane-patrol) which uses an LLM.

**Acceptable in scripts:**
- Transport (tmux interaction, file I/O, process inspection for PIDs)
- Agent name normalization (mapping LLM output to canonical tool names)
- Session ID extraction (reading state files, parsing process args)
- Configuration and error handling

**Not acceptable in scripts:**
- Regex or pattern matching on process names to detect agents
- Hardcoded lists of agent binary names or paths
- Interpreting pane/screen content
- Heuristics to determine if something is an agent

See [docs/design-principles.md](docs/design-principles.md) for the full
ZFC specification.

## Architecture

- `hooks/` -- Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/` -- tmux-resurrect post-save/post-restore hooks (collect and replay session IDs)
- `config/` -- tmux configuration snippet (TPM + resurrect + continuum settings)
- `docs/` -- Design principles and ZFC documentation
- `justfile` -- Installation, management, and debugging recipes

## Key conventions

- All scripts use `set -euo pipefail`
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `/tmp/tmux-assistant-resurrect/`)
- Log files go to `~/.tmux/resurrect/assistant-{save,restore}.log`
- Process inspection uses `ps -eo pid=,ppid=` (not `pgrep -P` -- unreliable on macOS)
- Agent detection is done by `pane-patrol scan` (ZFC), never by grep patterns
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

1. No code changes needed for detection -- pane-patrol's LLM handles it
2. Add a normalization case in `save-assistant-sessions.sh` (`normalize_agent`)
3. Add a `get_<tool>_session` function for session ID extraction
4. Add a restore command in `scripts/restore-assistant-sessions.sh`
5. Optionally add a hook/plugin in `hooks/` if the tool doesn't expose session IDs externally
6. Update install/uninstall recipes in `justfile` if a new hook was added

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add support for <tool>`
- `fix: handle <edge case>`
- `docs: update README`
