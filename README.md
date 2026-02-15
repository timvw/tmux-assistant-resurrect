# tmux-assistant-resurrect

> **Disclaimer**: This project was entirely vibecoded (designed and implemented
> through conversation with an AI coding assistant). It has **not yet been tested
> in real-world usage** beyond initial dry-runs against live tmux panes. Use at
> your own risk, and expect rough edges. Contributions and bug reports welcome.

Persist and restore AI coding assistant sessions across tmux restarts and reboots.

When your computer shuts down, tmux sessions are lost -- including any running
[Claude Code](https://github.com/anthropics/claude-code),
[OpenCode](https://github.com/opencode-ai/opencode), or
[Codex CLI](https://github.com/openai/codex) instances. This project hooks into
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) to
automatically save assistant session IDs and re-launch them with the correct
`--resume` flags after a restore.

## How it works

```
SAVE (every 10 min + manual prefix+Ctrl-s)
  tmux-resurrect saves pane layouts
    -> post-save hook inspects child processes of each pane
    -> detects assistants by binary name (claude, opencode, codex)
    -> extracts session IDs via native hooks/plugins/process args
    -> writes ~/.tmux/resurrect/assistant-sessions.json

RESTORE (on tmux start or manual prefix+Ctrl-r)
  tmux-resurrect restores pane layouts
    -> post-restore hook reads assistant-sessions.json
    -> sends resume commands to each pane:
         claude --resume <session-id>
         opencode -s <session-id>
         codex resume <session-id>
```

## Design

Detection is done via direct process inspection: the save script takes a
single `ps` snapshot of all processes, finds children of each tmux pane shell,
and matches known assistant binary names (`claude`, `opencode`, `codex`).

Session ID extraction uses tool-native mechanisms (infrastructure plumbing):

| Tool | Detection method | Reliability |
|------|-----------------|-------------|
| **Claude Code** | `SessionStart` hook writes session ID to state file | High -- native hook, event-driven |
| **OpenCode** | `-s` flag in process args; plugin state file as fallback | High -- handles runtime session switches |
| **Codex CLI** | PID lookup in `~/.codex/session-tags.jsonl` | High -- Codex writes PID natively |

For OpenCode, the `-s <session-id>` flag in process args is checked first as a
fast path. The plugin state file is the fallback (and handles the case where a
user switches sessions at runtime via `/sessions`).

## Prerequisites

- [tmux](https://github.com/tmux/tmux) (tested with 3.x)
- [TPM](https://github.com/tmux-plugins/tpm) (Tmux Plugin Manager)
- [jq](https://jqlang.github.io/jq/) (used by save/restore scripts)
- At least one of: Claude Code, OpenCode, Codex CLI

## Installation

### Via TPM (recommended)

Add to your `~/.tmux.conf`:

```bash
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'timvw/tmux-assistant-resurrect'

# Initialize TPM (must be last line)
run '~/.tmux/plugins/tpm/tpm'
```

Then press `prefix + I` inside tmux. TPM will clone the plugin and
automatically set up:

- tmux-resurrect + tmux-continuum settings
- Claude Code hooks in `~/.claude/settings.json`
- OpenCode session-tracker plugin in `~/.config/opencode/plugins/`

### Via git clone + just

```bash
git clone https://github.com/timvw/tmux-assistant-resurrect.git
cd tmux-assistant-resurrect
just install
```

After installation, reload tmux and install TPM plugins:

```bash
tmux source-file ~/.tmux.conf
# Inside tmux, press: prefix + I
```

## Uninstallation

### TPM

Remove the `@plugin 'timvw/tmux-assistant-resurrect'` line from `~/.tmux.conf`,
then press `prefix + alt + u` inside tmux.

The Claude hooks and OpenCode plugin are cleaned up automatically when the
plugin is removed.

### just

```bash
just uninstall
```

Removes all hooks, plugins, and tmux config entries.

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
tmux-assistant-resurrect.tmux     # TPM plugin entry point
config/
  resurrect-assistants.conf       # tmux config (used by just install, not TPM)
hooks/
  claude-session-track.sh         # Claude SessionStart hook (writes session ID)
  claude-session-cleanup.sh       # Claude SessionEnd hook (removes state file)
  opencode-session-track.js       # OpenCode plugin (tracks session ID + cleanup)
scripts/
  save-assistant-sessions.sh      # Resurrect post-save hook (process detection + session IDs)
  restore-assistant-sessions.sh   # Resurrect post-restore hook (resumes assistants)
test/
  Dockerfile                      # Docker image with tmux, jq, just, and mock assistants
  run-tests.sh                    # Integration test suite
justfile                          # Install/uninstall/status/save/restore/test recipes
```

## Testing

Integration tests run in Docker with mock assistant binaries:

```bash
just test
```

This builds a Docker image with tmux, jq, just, and mock `claude`/`opencode`/`codex`
binaries, then runs the full test suite covering install, save, restore, uninstall,
hooks, cleanup, and TPM plugin installation.

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

1. **Detection**: Add a `case` pattern in `detect_tool()` in
   `scripts/save-assistant-sessions.sh` matching the tool's binary name
2. **Session ID extraction**: Add a `get_<tool>_session()` function
3. **Restore command**: Add a `case` branch in
   `scripts/restore-assistant-sessions.sh` with the tool's resume command
4. **Session tracking** (optional): If the tool doesn't expose its session ID in
   process args or a known file, create a hook/plugin similar to the existing
   ones
5. Update install/uninstall recipes in `justfile` if a new hook was added

## How each component works

### Claude Code hooks (`hooks/claude-session-track.sh`, `hooks/claude-session-cleanup.sh`)

Two hooks configured in `~/.claude/settings.json`:

- **`SessionStart`**: Claude Code passes JSON on stdin (including `session_id`).
  The hook writes this to `/tmp/tmux-assistant-resurrect/claude-<PPID>.json`,
  where PPID is the parent shell process in the tmux pane.
- **`SessionEnd`**: Removes the state file when the Claude session exits,
  preventing stale entries.

### OpenCode plugin (`hooks/opencode-session-track.js`)

An OpenCode plugin that listens for `session.created`, `session.updated`, and
`session.idle` events. On each event, it writes the current session ID to
`/tmp/tmux-assistant-resurrect/opencode-<PID>.json`. This handles the case where
a user switches sessions at runtime (via `/sessions` or `Ctrl+x l`). The plugin
also cleans up its state file on process exit (SIGINT, SIGTERM).

### Codex CLI

Codex natively writes PID-to-session mappings in
`~/.codex/session-tags.jsonl`. The save script reads this file directly -- no
additional hook is needed.

### Save hook (`scripts/save-assistant-sessions.sh`)

Runs after each tmux-resurrect save. Takes a single `ps` snapshot of all
processes, finds children of each tmux pane's shell, and detects assistants by
matching binary names. Then extracts session IDs using tool-specific methods
(state files, process args, JSONL lookup). Writes results to
`~/.tmux/resurrect/assistant-sessions.json`.

### Restore hook (`scripts/restore-assistant-sessions.sh`)

Runs after each tmux-resurrect restore. Reads the sidecar JSON and sends the
appropriate resume command to each pane via `tmux send-keys`.

## Limitations

- **Running state is not preserved**: Assistants restart with their conversation
  history loaded, but any in-flight tool calls or pending operations are lost.
- **OpenCode without plugin**: If the OpenCode plugin isn't installed and the
  process was started without `-s`, the session ID cannot be detected. Install
  the plugin via `just install-opencode-plugin`.
- **Process inspection on macOS**: Uses `ps -eo pid=,ppid=` instead of `pgrep -P`
  due to reliability issues with `pgrep` on macOS.
- **Pane matching after restore**: tmux-resurrect preserves pane indices, so the
  restore hook targets the same `session:window.pane` addresses. If you manually
  rearrange panes between save and restore, the mapping may be wrong.

## License

MIT
