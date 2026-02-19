## Demo recording

This repo includes a shellwright-driven demo that records the full save → kill-server → restore cycle with live assistant sessions.

The recording shows:
- Running tmux sessions
- Active windows and panes (including current command)
- Assistant session IDs captured to `assistant-sessions.json`
- A full restore after `tmux kill-server`
- A resumed OpenCode TUI with conversation history

### Prerequisites

- `ssh aspire` works (configured host alias)
- tmux, tmux-resurrect, tmux-continuum, and this plugin are installed on `aspire`
- Claude Code + OpenCode are running in tmux sessions on `aspire`
- Local tools:
  - Node.js (for shellwright)
  - `uv` (for running the MCP client)

### Run the recording

1. Start shellwright:

```bash
npx -y @dwmkerr/shellwright --http --font-size 16 --cols 140 --rows 35
```

2. Run the demo script:

```bash
uv run --with "mcp[cli]" python demo/record.py
```

### Outputs

- `demo/output/demo-save-restore.gif` — the recording output
- `docs/images/demo-save-restore.gif` — the tracked asset used by the README

### What the demo does

The script drives tmux from outside tmux (no prefix keys), which is more reliable in automated terminals:

1. `tmux list-sessions`
2. `tmux list-windows -a` and `tmux list-panes -a`
3. `tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh`
4. `cat ~/.tmux/resurrect/assistant-sessions.json | jq ...`
5. `tmux kill-server`
6. `tmux list-sessions` (shows no server)
7. `tmux new-session -d -s main`
8. `tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/restore.sh`
9. `tmux list-sessions` + `tmux list-windows/panes` (shows restored state)
10. `tmux attach -t skynet` (shows OpenCode TUI with restored history)

### Troubleshooting

- **No sessions restored**: check `~/.tmux/resurrect/assistant-restore.log`
- **Session IDs missing**: verify state files in `$XDG_RUNTIME_DIR/tmux-assistant-resurrect/`
- **OpenCode or Claude missing**: ensure the sessions are running in tmux before recording
- **Nested tmux error**: the script runs `unset TMUX` before `tmux attach`
