# Try it yourself

[← Back to README](../README.md)

You can verify the full save → kill → restore cycle on your own machine using
the normal TPM installation — no cloning or build tools needed.

**Prerequisites**: tmux and jq. To see something come back, you also need at
least one [supported assistant](../README.md) installed.

## 1. Install

Follow the [Installation](../README.md#installation) steps (install TPM, add the
plugin lines to `~/.tmux.conf`, press `prefix + I` inside tmux).

## 2. Launch some assistants

Start assistants in separate tmux windows or sessions — just like you normally
would:

```bash
# In one tmux window:
cd ~/src/my-project
claude

# In another window:
cd ~/src/other-project
opencode

# Or in another window:
cd ~/src/yet-another-project
pi
```

Work with them for a bit so the session hooks fire (Claude's `SessionStart`
hook writes the session ID to disk automatically).

## 3. Save

Press `prefix + Ctrl-s` (the tmux-resurrect save keybinding). This saves the
tmux layout **and** runs the assistant save hook, which detects running
assistants and writes their session IDs to `assistant-sessions.json` inside
tmux-resurrect's save directory.

> **Save location.** The hook writes next to tmux-resurrect's own saves,
> resolved exactly as resurrect resolves it: `@resurrect-dir` if you set it,
> otherwise `~/.tmux/resurrect` when that directory already exists, else the
> XDG default `${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect`. Set
> `TMUX_RESURRECT_DIR` to override.

Find your actual save directory with `just status` (from the plugin directory)
or this one-liner that mirrors the same resolution logic:

```bash
RESURRECT_DIR="${TMUX_RESURRECT_DIR:-$(tmux show-option -gqv @resurrect-dir 2>/dev/null)}"
[ -n "$RESURRECT_DIR" ] || { [ -d ~/.tmux/resurrect ] && RESURRECT_DIR=~/.tmux/resurrect || RESURRECT_DIR=${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect; }
```

You can inspect what was saved:

```bash
cat "$RESURRECT_DIR/assistant-sessions.json" | jq .
```

Example output:

```json
{
  "timestamp": "2026-02-15T20:34:28Z",
  "sessions": [
    {
      "pane": "my-project:0.0",
      "session_name": "my-project",
      "window_index": "0",
      "pane_index": "0",
      "tool": "claude",
      "session_id": "01abc...",
      "cwd": "/home/user/src/my-project",
      "pid": "12345",
      "model": "claude-opus-4-6",
      "cli_args": "--dangerously-skip-permissions --model claude-opus-4-6",
      "env": {"tmux_pane": "%1", "shell": "/bin/zsh", "ANTHROPIC_BASE_URL": "https://proxy.internal"}
    },
    {
      "pane": "other-project:0.0",
      "session_name": "other-project",
      "window_index": "0",
      "pane_index": "0",
      "tool": "opencode",
      "session_id": "ses_xyz...",
      "cwd": "/home/user/src/other-project",
      "pid": "12346",
      "model": "",
      "cli_args": "",
      "env": {"tmux_pane": "%2", "shell": "/bin/zsh"}
    }
  ],
  "relaunch": []
}
```

`session_name`, `window_index` and `pane_index` are the pane's address as three
separate values; `pane` is the same address joined into tmux's usual
`session:window.pane` display form. The joined form is kept because
tmux-resurrect's `pane_contents.tar.gz` names its members after it, but it is
not a usable tmux target — session names may contain `:` and `.`, which the
target grammar reserves. Restore matches the three parts against
`tmux list-panes` and works from the pane id it gets back.

## 4. Kill tmux (simulate a reboot)

```bash
tmux kill-server
```

Everything is gone — all sessions, all panes, all running assistants.

## 5. Restore

Start tmux again:

```bash
tmux
```

Then press `prefix + Ctrl-r` (the tmux-resurrect restore keybinding).

tmux-resurrect recreates your sessions, windows, and panes. The post-restore
hook then reads the saved assistant sessions and sends the correct resume
command to each pane, preserving the original CLI flags and environment:

- `claude --dangerously-skip-permissions --model opus --resume <session-id>`
- `opencode -s <session-id>`
- `ANTHROPIC_BASE_URL='...' codex resume <session-id>`
- `pi --model sonnet --session <session-id>`

If the session was launched with flags like `--dangerously-skip-permissions` or
`--model`, those flags are captured from `ps` at save time and replayed on
restore. Environment variables configured via `@assistant-resurrect-capture-env`
are prepended to the resume command.

## 6. Verify

Check the restore log to see what happened:

```bash
cat "$RESURRECT_DIR/assistant-restore.log"
```

You should see lines like:

```
[2026-02-15T20:34:31Z] restoring 2 assistant pane(s)...
[2026-02-15T20:34:31Z] restoring claude in my-project:0.0 (session: 01abc..., cmd: claude --dangerously-skip-permissions --resume '01abc...')
[2026-02-15T20:34:32Z] restoring opencode in other-project:0.0 (session: ses_xyz..., cmd: opencode -s 'ses_xyz...')
[2026-02-15T20:34:33Z] restored 2 of 2 assistant pane(s)
```

The save log is also available if you want to see what was detected:

```bash
cat "$RESURRECT_DIR/assistant-save.log"
```
