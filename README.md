# tmux-assistant-resurrect

> **Disclaimer**: This project was entirely vibecoded (designed and implemented
> through conversation with AI coding assistants). It has been end-to-end tested
> in Docker with real CLI binaries (91 automated tests + full save/kill/restore
> lifecycle smoke test), but has **limited real-world usage** so far. Expect
> rough edges. Contributions and bug reports welcome.

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
SAVE (every 5 min + manual prefix+Ctrl-s)
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

| Tool | Primary method | Fallback | Notes |
|------|---------------|----------|-------|
| **Claude Code** | `SessionStart` hook state file (keyed by Claude PID) | `--resume` in process args | Claude overwrites its process title, so args fallback only works if args are visible |
| **OpenCode** | `-s` / `--session` in process args | Plugin state file | Plugin handles runtime session switches via `/sessions` |
| **Codex CLI** | PID lookup in `~/.codex/session-tags.jsonl` | `resume` in process args | Codex runs via Node.js, so args are always visible in `ps` |

Each tool has a primary and fallback extraction method. Fallbacks address the
chicken-and-egg problem: after a restore, session IDs are in process args even
before hooks/plugins have fired.

## Prerequisites

- [tmux](https://github.com/tmux/tmux) (tested with 3.x)
- [TPM](https://github.com/tmux-plugins/tpm) (Tmux Plugin Manager)
- [jq](https://jqlang.github.io/jq/) (used by save/restore scripts)
- At least one of: Claude Code, OpenCode, Codex CLI

## Installation

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

## Uninstallation

Remove the `@plugin 'timvw/tmux-assistant-resurrect'` line from `~/.tmux.conf`,
then press `prefix + alt + u` inside tmux.

## Usage

### Automatic (recommended)

Once installed, everything runs automatically:

- **tmux-continuum** saves your tmux layout every 5 minutes
- **Post-save hook** collects assistant session IDs at each save
- **On tmux server start**, continuum auto-restores the layout
- **Post-restore hook** resumes each assistant with its saved session ID

Manual save/restore keybindings (tmux-resurrect defaults):

| Key | Action |
|-----|--------|
| `prefix + Ctrl-s` | Save tmux state + assistant sessions |
| `prefix + Ctrl-r` | Restore tmux state + resume assistants |

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
  lib-detect.sh                   # Shared library (detect_tool, pane_has_assistant, posix_quote)
  save-assistant-sessions.sh      # Resurrect post-save hook (process detection + session IDs)
  restore-assistant-sessions.sh   # Resurrect post-restore hook (resumes assistants)
test/
  Dockerfile                      # Docker image with tmux, jq, just, and real assistant CLIs
  run-tests.sh                    # Integration test suite (91 tests)
justfile                          # Install/uninstall/status/save/restore/test recipes
```

## Testing

### Automated tests (Docker)

The full test suite runs in Docker with real CLI binaries (no mocks):

```bash
just test
```

This builds a Docker image with tmux, jq, just, and the real
`@anthropic-ai/claude-code`, `opencode-ai`, and `@openai/codex` npm packages,
then runs 91 tests covering install, save, restore, uninstall, hooks, cleanup,
TPM plugin installation, session ID extraction, POSIX quoting, process tree
detection, and regression scenarios. No API keys are needed — the tests exercise
the process detection and session management layer, not the AI functionality.

### Try it yourself

You can verify the full save → kill → restore cycle on your own machine using
the normal TPM installation — no cloning or build tools needed.

**Prerequisites**: tmux, jq, and at least one of claude / opencode / codex
installed.

#### 1. Install via TPM

Add to your `~/.tmux.conf` (if you haven't already):

```bash
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'timvw/tmux-assistant-resurrect'

run '~/.tmux/plugins/tpm/tpm'
```

Then inside tmux, press `prefix + I` (capital I). TPM will install the plugins
and set up the Claude hooks and OpenCode plugin automatically.

#### 2. Launch some assistants

Start assistants in separate tmux windows or sessions — just like you normally
would:

```bash
# In one tmux window:
cd ~/src/my-project
claude

# In another window:
cd ~/src/other-project
opencode
```

Work with them for a bit so the session hooks fire (Claude's `SessionStart`
hook writes the session ID to disk automatically).

#### 3. Save

Press `prefix + Ctrl-s` (the tmux-resurrect save keybinding). This saves the
tmux layout **and** runs the assistant save hook, which detects running
assistants and writes their session IDs to
`~/.tmux/resurrect/assistant-sessions.json`.

You can inspect what was saved:

```bash
cat ~/.tmux/resurrect/assistant-sessions.json | jq .
```

Example output:

```json
{
  "timestamp": "2026-02-15T20:34:28Z",
  "sessions": [
    {
      "pane": "my-project:0.0",
      "tool": "claude",
      "session_id": "01abc...",
      "cwd": "/home/user/src/my-project",
      "pid": "12345"
    },
    {
      "pane": "other-project:0.0",
      "tool": "opencode",
      "session_id": "ses_xyz...",
      "cwd": "/home/user/src/other-project",
      "pid": "12346"
    }
  ]
}
```

#### 4. Kill tmux (simulate a reboot)

```bash
tmux kill-server
```

Everything is gone — all sessions, all panes, all running assistants.

#### 5. Restore

Start tmux again:

```bash
tmux
```

Then press `prefix + Ctrl-r` (the tmux-resurrect restore keybinding).

tmux-resurrect recreates your sessions, windows, and panes. The post-restore
hook then reads the saved assistant sessions and sends the correct resume
command to each pane:

- `claude --resume <session-id>` for Claude
- `opencode -s <session-id>` for OpenCode
- `codex resume <session-id>` for Codex

Each assistant should launch in the correct working directory and resume its
previous conversation.

#### 6. Verify

Check the restore log to see what happened:

```bash
cat ~/.tmux/resurrect/assistant-restore.log
```

You should see lines like:

```
[2026-02-15T20:34:31Z] restoring 2 assistant session(s)...
[2026-02-15T20:34:31Z] restoring claude in my-project:0.0 (session: 01abc...)
[2026-02-15T20:34:32Z] restoring opencode in other-project:0.0 (session: ses_xyz...)
[2026-02-15T20:34:33Z] restored 2 of 2 assistant session(s)
```

The save log is also available if you want to see what was detected:

```bash
cat ~/.tmux/resurrect/assistant-save.log
```

### Troubleshooting

| Symptom | Check |
|---------|-------|
| Save finds 0 sessions | Run `ps -eo pid=,ppid=,args= \| grep -E 'claude\|opencode\|codex'` to verify assistants are running |
| Session ID missing for Claude | Verify the hook is installed: `jq '.hooks.SessionStart' ~/.claude/settings.json` |
| Session ID missing for OpenCode | Launch with `-s <id>`, or verify the plugin: `ls ~/.config/opencode/plugins/session-tracker.js` |
| Restore launches but assistant says "session not found" | The session ID may have expired. This is normal — start a fresh session and the next save will pick up the new ID |
| Assistants launch twice after restore | Make sure assistants are **not** listed in `@resurrect-processes` — the plugin handles all resuming via the post-restore hook |
| `just test` fails with Docker errors | Ensure Docker is running and you have network access (the image pulls npm packages) |

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
set -g @continuum-save-interval '5'  # minutes
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
  The hook writes this to `/tmp/tmux-assistant-resurrect/claude-<PID>.json`,
  where PID is Claude Code's process ID (the hook's `$PPID`, since Claude
  spawns the hook as a subprocess).
- **`SessionEnd`**: Removes the state file when the Claude session exits,
  preventing stale entries.

**Note**: Claude Code overwrites its process title (`process.title = 'claude'`),
so `--resume <session-id>` is not visible in `ps` output. The state file is the
only reliable source of session IDs for Claude.

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
- **First save after install (chicken-and-egg)**: On initial install, no session
  IDs exist yet. Assistants must complete at least one session (triggering the
  hooks) before their IDs can be saved. For Codex and OpenCode with `-s`, this
  is not an issue since session IDs are visible in process args.
- **Claude process title**: Claude Code overwrites its process title, so
  `--resume` flags are not visible in `ps`. The `SessionStart` hook is the only
  reliable source of Claude session IDs.
- **OpenCode without plugin**: If the OpenCode plugin isn't installed and the
  process was started without `-s`, the session ID cannot be detected.
- **Process inspection on macOS**: Uses `ps -eo pid=,ppid=` instead of `pgrep -P`
  due to reliability issues with `pgrep` on macOS.
- **Pane matching after restore**: tmux-resurrect preserves pane indices, so the
  restore hook targets the same `session:window.pane` addresses. If you manually
  rearrange panes between save and restore, the mapping may be wrong.

## License

MIT
