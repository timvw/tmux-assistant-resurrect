# tmux-assistant-resurrect

Persist and restore AI coding assistant sessions across tmux restarts and reboots.

When your computer shuts down, tmux sessions are lost -- including any running
Claude Code, OpenCode, or Codex CLI instances. This project hooks into
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) to
automatically save assistant session IDs and re-launch them with the correct
`--resume` flags after a restore.

## How it works

```
SAVE (every 10 min + manual prefix+Ctrl-s)
  tmux-resurrect saves pane layouts
    -> post-save hook iterates all panes
    -> detects running assistants (claude, opencode, codex)
    -> extracts session IDs via native hooks/plugins/files
    -> writes ~/.tmux/resurrect/assistant-sessions.json

RESTORE (on tmux start or manual prefix+Ctrl-r)
  tmux-resurrect restores pane layouts
    -> post-restore hook reads assistant-sessions.json
    -> sends resume commands to each pane:
         claude --resume <session-id>
         opencode -s <session-id>
         codex resume <session-id>
```

## Session ID detection

Each tool uses a different mechanism to track its active session ID:

| Tool | Detection method | Reliability |
|------|-----------------|-------------|
| **Claude Code** | `SessionStart` hook writes session ID to state file | High -- native hook, event-driven |
| **OpenCode** | Plugin writes session ID on `session.created/updated/idle` | High -- handles runtime session switches |
| **Codex CLI** | PID lookup in `~/.codex/session-tags.jsonl` | High -- Codex writes PID natively |

For OpenCode, the `-s <session-id>` flag in process args is checked first as a
fast path. The plugin state file is the fallback (and handles the case where a
user switches sessions at runtime via `/sessions`).

## Prerequisites

- [tmux](https://github.com/tmux/tmux) (tested with 3.x)
- [jq](https://jqlang.github.io/jq/) (used by save/restore scripts)
- [just](https://just.systems/) (task runner)
- At least one of: Claude Code, OpenCode, Codex CLI

## Installation

```bash
cd ~/src/timvw/tmux-assistant-resurrect
just install
```

This will:

1. Install [TPM](https://github.com/tmux-plugins/tpm) (Tmux Plugin Manager) if
   not present
2. Add a `SessionStart` hook to `~/.claude/settings.json` (Claude Code)
3. Symlink a session-tracker plugin into `~/.config/opencode/plugins/` (OpenCode)
4. Append a `source-file` directive and TPM init to `~/.tmux.conf`

After installation, complete the setup:

```bash
# Reload tmux config
tmux source-file ~/.tmux.conf

# Install TPM plugins (inside tmux, press):
#   prefix + I    (capital I)

# Verify everything
just status
```

## Uninstallation

```bash
just uninstall
```

Removes all hooks, plugins, and tmux config entries. Optionally remove TPM:

```bash
rm -rf ~/.tmux/plugins/
tmux source-file ~/.tmux.conf
```

## Usage

### Automatic (recommended)

Once installed, everything runs automatically:

- **tmux-continuum** saves your tmux layout every 10 minutes
- **Post-save hook** collects assistant session IDs at each save
- **On tmux server start**, continuum auto-restores the layout
- **Post-restore hook** resumes each assistant with its saved session ID

Manual save/restore keybindings (tmux-resurrect defaults):

| Key | Action |
|-----|--------|
| `prefix + Ctrl-s` | Save tmux state + assistant sessions |
| `prefix + Ctrl-r` | Restore tmux state + resume assistants |

### Manual commands

```bash
# Save current assistant sessions (without full tmux save)
just save

# Restore saved assistant sessions into current panes
just restore

# Check installation status and tracked sessions
just status

# Clean up state files from dead processes
just clean
```

## Repository structure

```
config/
  resurrect-assistants.conf     # tmux config: TPM + resurrect + continuum + hooks
hooks/
  claude-session-track.sh       # Claude SessionStart hook script
  opencode-session-track.js     # OpenCode session-tracker plugin
scripts/
  save-assistant-sessions.sh    # Resurrect post-save hook
  restore-assistant-sessions.sh # Resurrect post-restore hook
justfile                        # Install/uninstall/status/save/restore recipes
```

## Configuration

### State directory

Session tracking files are written to `/tmp/tmux-assistant-resurrect/` by
default. Override with:

```bash
export TMUX_ASSISTANT_RESURRECT_DIR=/path/to/state
```

### Continuum save interval

Edit `config/resurrect-assistants.conf`:

```
set -g @continuum-save-interval '10'  # minutes
```

### Adding support for a new assistant

To add a new AI coding assistant:

1. **Detection**: Add a `case` branch in `scripts/save-assistant-sessions.sh`
   that matches the process name and extracts the session ID
2. **Restore command**: Add a `case` branch in
   `scripts/restore-assistant-sessions.sh` with the tool's resume command
3. **Session tracking** (optional): If the tool doesn't expose its session ID in
   process args or a known file, create a hook/plugin similar to the existing
   ones

## How each component works

### Claude Code hook (`hooks/claude-session-track.sh`)

Configured as a `SessionStart` hook in `~/.claude/settings.json`. Claude Code
passes JSON on stdin to all hooks, including the `session_id` field. The script
writes this to `/tmp/tmux-assistant-resurrect/claude-<PPID>.json`, where PPID is
the parent shell process in the tmux pane.

### OpenCode plugin (`hooks/opencode-session-track.js`)

An OpenCode plugin that listens for `session.created`, `session.updated`, and
`session.idle` events. On each event, it writes the current session ID to
`/tmp/tmux-assistant-resurrect/opencode-<PID>.json`. This handles the case where
a user switches sessions at runtime (via `/sessions` or `Ctrl+x l`).

### Codex CLI

Codex natively writes PID-to-session mappings in
`~/.codex/session-tags.jsonl`. The save script reads this file directly -- no
additional hook is needed.

### Save hook (`scripts/save-assistant-sessions.sh`)

Runs after each tmux-resurrect save. Iterates all tmux panes, finds child
processes matching known assistants, extracts session IDs using the methods
above, and writes `~/.tmux/resurrect/assistant-sessions.json`.

### Restore hook (`scripts/restore-assistant-sessions.sh`)

Runs after each tmux-resurrect restore. Reads the sidecar JSON and sends the
appropriate resume command to each pane via `tmux send-keys`.

## Limitations

- **Running state is not preserved**: Assistants restart with their conversation
  history loaded, but any in-flight tool calls or pending operations are lost.
- **OpenCode without plugin**: If the OpenCode plugin isn't installed and the
  process was started without `-s`, the session ID cannot be detected. Install
  the plugin via `just install-opencode-plugin`.
- **Process detection on macOS**: Uses `ps -eo pid=,ppid=` instead of `pgrep -P`
  due to reliability issues with `pgrep` on macOS.
- **Pane matching after restore**: tmux-resurrect preserves pane indices, so the
  restore hook targets the same `session:window.pane` addresses. If you manually
  rearrange panes between save and restore, the mapping may be wrong.

## License

MIT
