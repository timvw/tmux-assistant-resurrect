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
    -> post-save hook calls pane-patrol scan (LLM classifies agents)
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

## Design: ZFC compliance

This project follows the **Zero False Commands** (ZFC) principle from
[pane-patrol](https://github.com/timvw/pane-patrol): **"Scripts transport. AI
decides."**

Agent detection (determining which panes run coding assistants) is delegated
entirely to [pane-patrol](https://github.com/timvw/pane-patrol), which uses an
LLM to classify each pane. No hardcoded process name patterns or heuristics.

Session ID extraction (reading state files, parsing process args) is
infrastructure plumbing and stays in scripts.

See [docs/design-principles.md](docs/design-principles.md) for the full
specification.

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
- [pane-patrol](https://github.com/timvw/pane-patrol) (agent detection via LLM)
- [jq](https://jqlang.github.io/jq/) (used by save/restore scripts)
- [just](https://just.systems/) (task runner)
- An LLM API key configured for pane-patrol (Anthropic or OpenAI)
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
AGENTS.md                         # Guidelines for AI coding agents (ZFC rules)
config/
  resurrect-assistants.conf       # tmux config: TPM + resurrect + continuum + hooks
docs/
  design-principles.md            # ZFC specification
hooks/
  claude-session-track.sh         # Claude SessionStart hook (writes session ID)
  claude-session-cleanup.sh       # Claude SessionEnd hook (removes state file)
  opencode-session-track.js       # OpenCode plugin (tracks session ID + cleanup)
scripts/
  save-assistant-sessions.sh      # Resurrect post-save hook (pane-patrol + session IDs)
  restore-assistant-sessions.sh   # Resurrect post-restore hook (resumes assistants)
justfile                          # Install/uninstall/status/save/restore recipes
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

1. **Detection**: No code changes needed -- pane-patrol's LLM handles it
2. **Name normalization**: Add a case in `normalize_agent()` in
   `scripts/save-assistant-sessions.sh` to map the LLM's agent name to a
   canonical tool name
3. **Session ID extraction**: Add a `get_<tool>_session()` function
4. **Restore command**: Add a `case` branch in
   `scripts/restore-assistant-sessions.sh` with the tool's resume command
5. **Session tracking** (optional): If the tool doesn't expose its session ID in
   process args or a known file, create a hook/plugin similar to the existing
   ones

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

Runs after each tmux-resurrect save. Calls `pane-patrol scan` to classify all
panes (ZFC: LLM decides what's an agent), then extracts session IDs for detected
agents using the tool-specific methods above. Writes the results to
`~/.tmux/resurrect/assistant-sessions.json`.

### Restore hook (`scripts/restore-assistant-sessions.sh`)

Runs after each tmux-resurrect restore. Reads the sidecar JSON and sends the
appropriate resume command to each pane via `tmux send-keys`.

## Limitations

- **pane-patrol required**: Agent detection requires
  [pane-patrol](https://github.com/timvw/pane-patrol) and a configured LLM API
  key. Each save triggers an LLM call per pane (~2-10s per pane, API costs
  apply).
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
