# tmux-assistant-resurrect

> **Disclaimer**: This project was entirely vibecoded (designed and implemented
> through conversation with AI coding assistants). It has been end-to-end tested
> in Docker with real CLI binaries (Claude/Copilot/OpenCode/Codex/Pi/Oh My Pi)
> (400+ automated tests + full save/kill/restore lifecycle smoke test).
> Grok is supported with hermetic unit tests but has no Docker integration test.
> **Limited real-world usage** so far — expect
> rough edges. Contributions and bug reports welcome.

Persist and restore AI coding assistant sessions across tmux restarts and reboots.

![Save, kill, and restore — assistant sessions resume automatically](docs/images/demo-save-restore.gif)

When your computer shuts down, tmux sessions are lost -- including any running
[Claude Code](https://github.com/anthropics/claude-code),
[GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli),
[OpenCode](https://github.com/opencode-ai/opencode),
[Codex CLI](https://github.com/openai/codex),
[Pi](https://github.com/mariozechner/pi),
[Oh My Pi](https://github.com/can1357/oh-my-pi), or
[Grok Build](https://x.ai/cli) (xAI's `grok` CLI / TUI, not the community
`grok-cli`) instances. This project hooks into
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) to
automatically save assistant session IDs, CLI flags, and environment variables,
then re-launch them with the exact same configuration after a restore.

## How it works

```
SAVE (every 5 min + manual prefix+Ctrl-s)
  tmux-resurrect saves pane layouts
    -> post-save hook inspects child processes of each pane
    -> detects assistants by binary name (claude, copilot, opencode, codex, pi, omp, grok)
    -> extracts session IDs via native hooks/plugins/process args
    -> writes assistant-sessions.json in tmux-resurrect's save dir

RESTORE (on tmux start or manual prefix+Ctrl-r)
  tmux-resurrect restores pane layouts
    -> post-restore hook reads assistant-sessions.json
    -> reconstructs full CLI invocation with saved flags + env vars
    -> sends resume commands to each pane, e.g.:
         ANTHROPIC_BASE_URL='...' claude --dangerously-skip-permissions --resume <id>
         copilot --allow-all --resume=<id>
         opencode --verbose -s <session-id>
         codex --full-auto resume <session-id>
         pi --model sonnet --session <session-id>
         omp --profile work --resume <session-id>
         grok --resume <session-id>
```

## Design

Detection is done via direct process inspection: the save script takes a
single `ps` snapshot of all processes, finds children of each tmux pane shell,
and matches known assistant binary names (`claude`, `copilot`, `opencode`,
`codex`, `pi`, `omp`, `grok`).

Session ID extraction uses tool-native mechanisms (infrastructure plumbing):

| Tool | Primary method | Fallback 1 | Fallback 2 | Notes |
|------|---------------|------------|------------|-------|
| **Claude Code** | `SessionStart` hook state file (keyed by Claude PID) | `--resume` / `--session-id` in process args | - | Claude overwrites its process title, so args fallback only works if args are visible |
| **GitHub Copilot CLI** | `$COPILOT_HOME/session-state/<uuid>/inuse.<pid>.lock` written by the live session | `--session-id` / `--resume` in process args | - | Plain glob keyed on the native PID — no `/proc`, no `lsof`, so it behaves identically on Linux, WSL and macOS |
| **OpenCode** | `-s` / `--session` in process args | Plugin state file | SQLite DB query (`~/.local/share/opencode/opencode.db`) | Go binary overwrites process title; DB fallback matches most recent session by cwd |
| **Codex CLI** | PID lookup in `~/.codex/session-tags.jsonl` | `resume` in process args | SQLite `~/.codex/state_*.sqlite` `threads` table (Codex >= 0.118); rollout JSONL `~/.codex/sessions/` (Codex ~0.100-0.117) | Codex runs via Node.js, so args are always visible in `ps` |
| **Pi** | Session header lookup in `~/.pi/agent/sessions/--<cwd>--/*.jsonl` | `--session` in process args | - | Session-file lookup is cwd-scoped and uses process-time scoring + dedup |
| **Oh My Pi** | Terminal breadcrumb + session JSONL lookup (`$XDG_STATE_HOME/omp`, `$XDG_DATA_HOME/omp`) | `--resume` / `-r` in process args | `--session-dir` / `--profile` scoped lookup | Distinct `omp` tool; no hook/plugin required |
| **Grok** | PID lookup in `~/.grok/active_sessions.json` | `-r` / `--resume <uuid>` in process args | - | Registry records every live session (including a bare `grok` with no args) keyed by PID, so sessions sharing a cwd never collide; no hook/plugin required |

Each tool has a primary and fallback extraction method. Fallbacks address the
chicken-and-egg problem: after a restore, session IDs are in process args even
before hooks/plugins have fired. The OpenCode SQLite database fallback provides
version-resilient session ID extraction even when the plugin hasn't fired.

## Prerequisites

- [tmux](https://github.com/tmux/tmux) (tested with 3.4 through 3.7)
- [TPM](https://github.com/tmux-plugins/tpm) (Tmux Plugin Manager)
- [jq](https://jqlang.github.io/jq/) (used by save/restore scripts)
- At least one of: Claude Code, GitHub Copilot CLI, OpenCode, Codex CLI, Pi,
  Oh My Pi, Grok

## Installation

Install [TPM](https://github.com/tmux-plugins/tpm) if you don't have it:

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Add to your `~/.tmux.conf`:

```bash
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'timvw/tmux-assistant-resurrect'

# Optional: restore terminal text in non-assistant panes after tmux restart.
# If enabled, the plugin automatically strips captured content for assistant
# panes so restore won't briefly flash stale TUI output before resuming.
# set -g @resurrect-capture-pane-contents 'on'

# Initialize TPM (must be last line)
run '~/.tmux/plugins/tpm/tpm'
```

Then inside tmux, press `prefix + I` (capital I). TPM will clone the plugins
and automatically set up:

- tmux-resurrect + tmux-continuum settings
- Claude Code hooks in `~/.claude/settings.json`
- Copilot support via its per-session `inuse.<pid>.lock` file (no hook/plugin required)
- OpenCode session-tracker plugin in `~/.config/opencode/plugins/`
- Pi support via session-file lookup in `~/.pi/agent/sessions` (no hook/plugin required)
- Oh My Pi support via terminal/session-file lookup in `$XDG_STATE_HOME/omp`, `$XDG_DATA_HOME/omp`, or `~/.omp` (no hook/plugin required)
- Grok support via the `~/.grok/active_sessions.json` registry (no hook/plugin required)

## Uninstallation

**TPM users**: Remove the `@plugin 'timvw/tmux-assistant-resurrect'` line from
`~/.tmux.conf`, then press `prefix + alt + u` inside tmux.

**`just install` users**: Run `just uninstall` from the plugin directory — this
removes the Claude hooks, the OpenCode plugin symlink, and the managed block
from `~/.tmux.conf`.

## Usage

### Automatic (recommended)

Once installed, everything runs automatically:

- **tmux-continuum** saves your tmux layout every 5 minutes
- **Post-save hook** collects assistant session IDs at each save
- **On tmux server start**, continuum auto-restores the layout
- **Post-restore hook** resumes each assistant with its saved session ID

The plugin defaults `@continuum-save-interval` to 5 and `@continuum-restore` to
`on`, but only when they are not already set — your own values in `~/.tmux.conf`
are never overwritten.

Manual save/restore keybindings (tmux-resurrect defaults):

| Key | Action |
|-----|--------|
| `prefix + Ctrl-s` | Save tmux state + assistant sessions |
| `prefix + Ctrl-r` | Restore tmux state + resume assistants |

## Repository structure

```
tmux-assistant-resurrect.tmux     # TPM plugin entry point
config/
  resurrect-assistants.conf       # tmux config reference template (not sourced automatically)
hooks/
  lib-claude-pid.sh               # Shared helper: walks process tree to find Claude PID
  claude-session-track.sh         # Claude SessionStart hook (writes session ID)
  claude-session-cleanup.sh       # Claude SessionEnd hook (removes state file)
  opencode-session-track.js       # OpenCode plugin (tracks session ID + cleanup)
scripts/
  lib-detect.sh                   # Shared library (detect_tool, pane_has_assistant, posix_quote)
  save-assistant-sessions.sh      # Resurrect post-save hook (process detection + session IDs)
  restore-assistant-sessions.sh   # Resurrect post-restore hook (resumes assistants)
  py/                             # Helper programs invoked by the save hook via argv
                                  #   (never via shell heredocs — see issue #48)
test/
  Dockerfile                      # Docker image with tmux, jq, just, and real assistant CLIs
  bench-save-hook.sh              # Single-scenario save-hook benchmark runner (inside Docker)
  bench-matrix.sh                 # Docker benchmark matrix + CSV/Markdown summary generator
  run-tests.sh                    # Integration test suite
justfile                          # Install/uninstall/status/save/restore/test recipes
```

## Testing

### Automated tests (Docker)

The full test suite runs in Docker with real CLI binaries (no mocks):

```bash
just test
```

Fast hermetic suites cover the hardened save, restore, and installer paths:

```bash
just test-save-hardening
just test-restore
just test-plugin-hardening
```

This builds a Docker image with tmux, jq, just, and the real
`@anthropic-ai/claude-code`, `opencode-ai`, `@openai/codex`, and
`@earendil-works/pi-coding-agent` npm packages, then runs the full test suite
covering install, save, restore, uninstall, hooks, cleanup, TPM plugin
installation, session ID extraction, POSIX quoting, process tree detection,
upgrade-path migration, and regression scenarios. Pi runs with `--offline` flag
(stays alive as TUI without API key). No API keys are needed — the
tests exercise the process detection and session management layer, not the AI
functionality.

### Performance benchmarks (Docker)

Run a benchmark matrix and capture results as CSV + Markdown:

```bash
just benchmark
```

To compare your current checkout against another repo path (for example a
worktree on `main`):

```bash
just benchmark base_repo=/path/to/base/worktree
```

Results are written to:

- `test-results/benchmark.csv`
- `test-results/benchmark.md`

On GitHub Actions (`.github/workflows/test.yml`), the benchmark matrix runs on
every push/PR, publishes a step-summary table, and uploads the same CSV/Markdown
files as the `benchmark-results` artifact.

### Try it yourself

You can verify the full save → kill → restore cycle on your own machine using
the normal TPM installation — no cloning or build tools needed.

**Prerequisites**: tmux, jq, and at least one of claude / copilot / opencode /
codex / pi
installed.

#### 1. Install

Follow the [Installation](#installation) steps above (install TPM, add the
plugin lines to `~/.tmux.conf`, press `prefix + I` inside tmux).

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

# Or in another window:
cd ~/src/yet-another-project
pi
```

Work with them for a bit so the session hooks fire (Claude's `SessionStart`
hook writes the session ID to disk automatically).

#### 3. Save

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
RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
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
command to each pane, preserving the original CLI flags and environment:

- `claude --dangerously-skip-permissions --model opus --resume <session-id>`
- `opencode -s <session-id>`
- `ANTHROPIC_BASE_URL='...' codex resume <session-id>`
- `pi --model sonnet --session <session-id>`

If the session was launched with flags like `--dangerously-skip-permissions` or
`--model`, those flags are captured from `ps` at save time and replayed on
restore. Environment variables configured via `@assistant-resurrect-capture-env`
are prepended to the resume command.

#### 6. Verify

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

### Troubleshooting

| Symptom | Check |
|---------|-------|
| Save finds 0 sessions | Run `ps -eo pid=,ppid=,args= \| grep -E 'claude\|copilot\|opencode\|codex\|pi\|omp\|grok'` to verify assistants are running |
| Session ID missing for Claude | Verify the hook is installed: `jq '.hooks.SessionStart' ~/.claude/settings.json` |
| Session ID missing, hook *is* installed | Check `assistant-save.log` — a `no session ID available` line names the state file it looked for. If that directory is empty but `ls ~/.local/state/tmux-assistant-resurrect` elsewhere is not, the two sides disagree on the path; see **State directory** below |
| Session ID missing for Copilot | Check `ls ~/.copilot/session-state/*/inuse.*.lock` — the number in the filename must be the native Copilot PID from `ps`. If you set `COPILOT_HOME`, the save hook must see it too (tmux hooks do not inherit your shell profile; use `tmux set-environment -g COPILOT_HOME ...`) |
| Session ID missing for OpenCode | Launch with `-s <id>`, or verify the plugin: `ls ~/.config/opencode/plugins/session-tracker.js` |
| Session ID missing for Pi | Verify session files exist under `~/.pi/agent/sessions/--<cwd>--/*.jsonl` and that pane cwd matches the Pi session cwd |
| Session ID missing for Grok | Verify `~/.grok/active_sessions.json` exists and contains an entry with your Grok process's PID: `jq '.[] | select(.pid == <PID>)' ~/.grok/active_sessions.json`. If you set `GROK_HOME`, the save hook must see it too — use `tmux set-environment -g GROK_HOME ...` |
| Session ID missing for Oh My Pi | The primary method is a terminal breadcrumb under `$XDG_STATE_HOME/omp` (or `~/.local/state/omp`); verify the pane tty matches the breadcrumb file. Fallback is `--resume` / `-r` in process args. `--session-dir` or `--profile` scoped JSONL lookup is also used when those flags are present |
| Codex/OpenCode/Pi session ID missing (python3 methods) | The save hook auto-detects `python3` in common locations. If your setup uses a non-standard path, set it in tmux: `set-environment -g PATH "/your/python3/dir:$PATH"` |
| Restore launches but assistant says "session not found" | The session ID may have expired. This is normal — start a fresh session and the next save will pick up the new ID |
| Assistants launch twice after restore | Make sure assistants are **not** listed in `@resurrect-processes` — the plugin handles all resuming via the post-restore hook |
| `just test` fails with Docker errors | Ensure Docker is running and you have network access (the image pulls npm packages) |

## Configuration

### State directory

Session tracking files are written to `$HOME/.local/state/tmux-assistant-resurrect`
on every platform.

The path is deliberately a plain `$HOME` literal, and deliberately does *not*
follow `XDG_STATE_HOME`, `XDG_RUNTIME_DIR` or `TMPDIR`. It is a rendezvous point
between two processes that never share an environment: the assistant's
SessionStart hook writes the files, and the save hook — a child of the tmux
server — reads them. Any environment variable in the path is a chance for the two
sides to disagree, and when they do the failure is silent: the save hook finds
nothing and records no session ID. (This is [issue #65][issue-65]: Claude Code's
`settings.json` can set `"env": {"TMPDIR": ...}`, which the hook inherits and the
tmux server does not.) `$HOME` is the one variable both sides already agree on.

To relocate the directory, set `TMUX_ASSISTANT_RESURRECT_DIR` **where both sides
see it** — exporting it from your shell profile reaches only the assistant and
reintroduces exactly the divergence above:

```bash
# in tmux.conf — reaches the save hook
set-environment -g TMUX_ASSISTANT_RESURRECT_DIR /path/to/state
```

```jsonc
// in ~/.claude/settings.json — reaches the SessionStart hook
{ "env": { "TMUX_ASSISTANT_RESURRECT_DIR": "/path/to/state" } }
```

State files track running assistant PIDs and session IDs; the persistent sidecar
JSON (`assistant-sessions.json`, in tmux-resurrect's save directory — see **Save
location** above) is what a restore reads. Because `$HOME` survives reboots
(where the old temporary directory did not), the save hook sweeps state files
whose process is gone on every run, so the directory does not grow without bound.

Upgrading from a version that used the temporary directory needs no action:
assistants already running when you upgrade have their state files migrated on
the next save. Because the old path resolved differently on either side — that
being the bug — the migration does not just re-evaluate the old expression here;
it sweeps every root a pre-upgrade hook could have landed on (`$XDG_RUNTIME_DIR`,
`/run/user/<uid>`, `$TMPDIR`, macOS's per-user `/var/folders/…/T` when this side
has no `$TMPDIR` of its own, and `/tmp`), skipping any it does not own. Where two
files claim the same PID the newer one wins, since PIDs are recycled. Files whose
assistant has since exited are dropped on the same pass.

Two caveats remain, by construction. `TMUX_ASSISTANT_RESURRECT_DIR` is honoured
independently on each side, so setting it in only one place *creates* the
divergence rather than fixing it — hence the two snippets above. And if the
assistant is launched with a different `$HOME` than the tmux server (a container,
a `sudo -H`, a per-project home), the two sides part company again; the override,
set on both, is the fix. When either happens the save log names the exact path it
searched, so the mismatch is visible rather than silent.

[issue-65]: https://github.com/timvw/tmux-assistant-resurrect/issues/65

### Environment variable capture and restoration

By default, the plugin captures `TMUX_PANE` and `SHELL` in hook/plugin-backed
assistant state files (Claude/OpenCode). To capture additional environment
variables, set a space-separated list in `tmux.conf`:

```bash
set -g @assistant-resurrect-capture-env 'VIRTUAL_ENV NODE_ENV CONDA_DEFAULT_ENV'
```

Captured variables are stored in the state file's `env` object and propagated
to `assistant-sessions.json`. On restore, variables listed in
`@assistant-resurrect-capture-env` are prepended to the resume command:

```
VIRTUAL_ENV='/home/user/.venv' claude --resume <session-id>
```

**Tools without a session hook** (Copilot, Codex, Pi, Oh My Pi, Grok) have no state file
to capture from at launch. On **Linux and WSL**, the save hook instead reads the
configured variables straight from each detected assistant's environment via
`/proc/<pid>/environ`, so values like `CODEX_HOME` survive a restart. Only the
variables you list in `@assistant-resurrect-capture-env` are read — nothing else
is inspected — and where a value is available from both a session hook and the
live process, the live process wins.

> **Platform note:** Reading another process's environment is only possible
> unprivileged on **Linux/WSL** (`/proc`). macOS withholds it even for your own
> processes, so there hookless tools capture no env at save time. If you need a
> fixed value on macOS, export it in your shell profile (the restored pane
> inherits it) or set it globally with `tmux set-environment -g VAR value`.

Built-in variables (`TMUX_PANE`, `SHELL`) are **not** restored — `TMUX_PANE`
would be stale after restore, and `SHELL` is already in the environment.
State files are written atomically with mode 0600. The default state directory
is created mode 0700, and its parents (`~/.local`, `~/.local/state`) are left at
your umask. The persistent sidecar and save/restore logs are also owner-only,
and the plugin refuses to append through a symlinked log path. A state directory
that already exists keeps whatever mode you gave it — if you point
`TMUX_ASSISTANT_RESURRECT_DIR` somewhere deliberately group-readable, that is
respected rather than reset on every save.

> **Note:** Avoid capturing secrets (API keys, tokens). State files and the
> sidecar JSON persist to disk and may outlive the process they were captured
> from.

### Session-less relaunch vouchers

Long-lived modes such as `claude agents`, `claude gateway`, and
`claude mcp serve` do not have a resumable session ID. The save hook proposes
short, structurally plausible commands in an advisory ledger, but it relaunches
nothing until you explicitly vouch the exact canonical command:

```bash
cd "${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins}/tmux-assistant-resurrect"
just relaunch-candidates
just relaunch-add 'claude agents'
```

The `cd` is required for a normal TPM installation because these commands are
recipes in the plugin's own `justfile`.

The voucher defaults to
`assistant-relaunch-allow.txt` beside tmux-resurrect's save files. It is plain
text: one canonical command per line, with blank lines and `#` comments ignored.
`just relaunch-seed` creates an empty documented file without authorizing
anything. Commands containing advisory hazard words require a final `--force`
argument to `relaunch-add`; that warning list is never consulted by save or
restore.

Authorization is fixed-string, whole-line equality. The sidecar stores vouched
panes under the sibling `.relaunch` key, but its `cmd` is only a lookup key.
Restore tokenizes and quotes the matching line read from the current voucher,
never the sidecar value, before sending it to the pane. A missing or empty
voucher therefore preserves the previous behavior: session-less panes return as
bare shells. This is why relaunch support can safely default to on.

Configure it in `tmux.conf` when needed:

```bash
# Disable all session-less relaunch handling.
set -g @assistant-resurrect-relaunch 'off'

# Store the voucher somewhere else.
set -g @assistant-resurrect-relaunch-allow-file '/path/to/assistant-relaunch-allow.txt'
```

### PATH in restricted environments (NixOS, systemd services)

When tmux runs as a systemd user service, the server inherits a stripped-down
`PATH` that may not include `python3`. The save hook automatically checks common
system locations (`/run/current-system/sw/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin`) and augments `PATH` if needed. This is a no-op
when `python3` is already on `PATH`.

If your `python3` is in a non-standard location, the recommended fix is at the
tmux level:

```bash
# In tmux.conf — ensures all hooks and plugins see the right PATH:
set-environment -g PATH "/your/custom/bin:/usr/local/bin:/usr/bin:/bin"
```

Or fix it in the systemd unit:

```ini
# ~/.config/systemd/user/tmux.service.d/override.conf
[Service]
Environment=PATH=/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin
```

### Continuum save interval

Add to `~/.tmux.conf`:

```bash
set -g @continuum-save-interval '10'  # minutes (default: 5)
```

### Save-hook timeout (watchdog)

Once the save hook reaches its main work — process detection, session-ID
extraction, and serialization, the phase where the issue #48 hang lived — a
watchdog bounds how long that phase can run and keeps blocked helper
subprocesses (`python3` on a locked database, a `stat` on a slow filesystem, a
hung `jq`) from accumulating. The default deadline is 60 seconds; a normal save
finishes in a few seconds even with many panes. To change it:

```bash
set -g @assistant-resurrect-save-timeout '90'   # seconds; 0 disables the watchdog
```

It can also be set via the `ASSISTANT_RESURRECT_SAVE_TIMEOUT` environment
variable (the tmux option takes precedence). When the deadline is exceeded the
watchdog first `SIGTERM`s the stuck worker subprocesses so a merely-wedged save
can unblock and finish; if the hook is still running shortly after, it escalates
to `SIGKILL` and terminates the save hook itself. The sidecar
`assistant-sessions.json` is written atomically (temp file + rename), so a
terminated or failed save never corrupts the previously saved sessions. A hard
timeout is reported on the hook's **stderr** (surfaced wherever tmux-resurrect
captures hook output) rather than to `assistant-save.log` — writing to the log
could itself block on the same stalled filesystem that triggered the timeout.

> **Scope:** the watchdog is armed at the start of the hook's main work, so it
> covers detection and serialization (where session-lookup helpers run). A short
> prologue — reading a couple of tmux options and creating temp files — runs
> before it is armed; that is the same set of tmux/filesystem calls the hook has
> always made, and if the tmux server itself is wedged it would not have
> triggered the save in the first place.

### Adding support for a new assistant

To add a new AI coding assistant:

1. **Detection**: Add a `case` pattern in `detect_tool()` in
   `scripts/lib-detect.sh` matching the tool's binary name
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

- **`SessionStart`**: Claude Code passes JSON on stdin (including `session_id`,
  `model`, `source`, `permission_mode`, `transcript_path`, and more). The hook
  merges the full JSON payload with plugin metadata (`tool`, `ppid`, `timestamp`,
  `env`) and writes it to `$STATE_DIR/claude-<PID>.json`. This means any new
  fields Claude adds in future versions are captured automatically.
- **`SessionEnd`**: Removes the state file when the Claude session exits,
  preventing stale entries.

**Note**: Claude Code sets `process.title = 'claude'`, but on macOS arm64
(v2.1.44+) `ps -eo args=` still shows full args. The state file remains the
primary source of session IDs, with process args as a fallback. CLI flags like
`--dangerously-skip-permissions` are captured from `ps` by the save script's
`extract_cli_args()` function.

### OpenCode plugin (`hooks/opencode-session-track.js`)

An OpenCode plugin that listens for `session.created`, `session.updated`, and
`session.idle` events. On each event, it captures the full session object
(including model, title, and other metadata) along with init-time context
(`process.argv`, client API surface) and writes it to
`$STATE_DIR/opencode-<PID>.json`. This handles the case where
a user switches sessions at runtime (via `/sessions` or `Ctrl+x l`). The plugin
also cleans up its state file on process exit (SIGINT, SIGTERM).

### Codex CLI

Codex natively writes PID-to-session mappings in
`~/.codex/session-tags.jsonl`. The save script reads this file directly -- no
additional hook is needed.

### GitHub Copilot CLI

A live Copilot session marks its own state directory with a lock file naming
the process that owns it:

```
~/.copilot/session-state/<uuid>/inuse.<native-pid>.lock
```

The save hook resolves the session with one glob against the detected PID. It is
PID-specific, so multiple Copilot sessions in the same directory stay
unambiguous. An in-process `/resume` can leave the prior session's lock behind,
so the newest valid lock for the PID is selected. Copilot runs as an npm loader
plus a native child; only the child owns the lock.

Copilot writes `session.db` into that directory once the conversation has real
content, and **only such a session can be resumed** — `--resume=<uuid>` on a
still-empty one exits with `No session, task, or name matched`. The save hook
therefore requires `session.db` before saving a session, so restore never
replays a command that would error in your pane. The lock still does the
PID-to-session mapping, so this gate costs nothing but a file test. If an
in-process `/resume` leaves more than one lock for the same process, the newest
one wins.

(Not to be confused with `session-store.db`, which lives at the root of
`~/.copilot`, is shared by every session, and cannot identify one.)
`COPILOT_HOME` replaces the whole `~/.copilot` path, and the save hook honors
it. On Linux/WSL the hook can read a process-only value from `/proc`; on macOS,
set it for tmux too (`tmux set-environment -g COPILOT_HOME ...`) or launch with
`--config-dir`. The resolved root is saved and replayed through `COPILOT_HOME`,
including paths containing spaces.

Neither the lock file nor the `session.db` gate is part of Copilot's documented
interface, so `test/copilot-contract-test.sh` asserts both against the real
binary (no authentication required) and fails loudly if a future release changes
them. The full authenticated round trip — prompt, save, kill, restore, and
confirm the conversation is still there — was verified by hand against 1.0.78.

An explicit `--session-id <uuid>` or `--resume <uuid>` in process args is the
fallback for the brief startup window before the lock exists. Restore uses
`copilot --resume=<uuid>`, preserves
operational flags such as `--allow-all` and `--autopilot`, and strips
session-selection flags. Because process inspection loses the quoting boundary
of multi-word `--prompt` and `--interactive` values, either initial-prompt flag
and all following argv are dropped rather than risk replaying prompt text into
the resumed session. If a restricting permission flag cannot be reconstructed
exactly, all replay flags are dropped and restore uses a bare resume rather than
risk silently widening the resumed agent's permissions.

### Pi

Pi stores sessions as JSONL files under `~/.pi/agent/sessions/--<cwd>--/`.
The save hook reads session headers (`type: "session"`, `id`, `cwd`,
`timestamp`) and scores candidates by process lifetime + file mtime, with
dedup across panes. If a pane was launched via restore, `--session <id>` in
process args is used as a direct fallback.

### Save hook (`scripts/save-assistant-sessions.sh`)

Runs after each tmux-resurrect save. Takes a single `ps` snapshot of all
processes, finds children of each tmux pane's shell, and detects assistants by
matching binary names. Then extracts session IDs using tool-specific methods
(state files, process args, JSONL lookup, session-file lookup). Also captures:

- **CLI flags** (`cli_args`): extracted from `ps` args with the binary name and
  session/resume args stripped (e.g., `--dangerously-skip-permissions --model opus`)
- **Model** (`model`): from state file (preferred) or `--model` in args (fallback)
- **Environment** (`env`): from state file (captured by hooks/plugins)
- **Copilot state root** (`copilot_home`): the resolved `COPILOT_HOME` or
  `--config-dir` root, replayed automatically so restore finds the same UUID

Writes everything to `assistant-sessions.json` in tmux-resurrect's save
directory (see **Save location** above). Vouched session-less modes are written
to the sibling `.relaunch` array; ordinary resumable entries retain the existing
`.sessions` schema.

Helper programs (SQLite/JSONL lookups, path resolution) live as standalone
files under `scripts/py/` and are handed to `python3` via argv. They are
deliberately **not** embedded as shell heredocs: on bash ≥ 5.1 a heredoc is
written to a pipe before its reader is exec'd, and on macOS under pipe-memory
pressure that write can block forever, hanging the hook (issue #48). A watchdog
(see **Save-hook timeout** above) bounds the detection/serialization phase as a
second line of defense.

### Restore hook (`scripts/restore-assistant-sessions.sh`)

Runs after each tmux-resurrect restore. Reads the sidecar JSON and reconstructs
the full CLI invocation for each assistant: `<env_prefix> <binary> <cli_args>
<resume_arg>`. Sends the command to each pane via `tmux send-keys`. If enriched
fields are missing (old-format JSON), falls back to bare resume commands. For a
`.relaunch` entry, it instead requires an exact current voucher match and builds
the command from the matching voucher line.

## Limitations

- **Running state is not preserved**: Assistants restart with their conversation
  history loaded, but any in-flight tool calls or pending operations are lost.
- **Deleted working directories are not replayed**: If a saved pane's working
  directory no longer exists, restore leaves that pane at its shell instead of
  launching the assistant in an unrelated fallback directory.
- **Session-less modes require one user action per command**: Until you add an
  observed command to the voucher, that pane deliberately returns as a shell.
- **The voucher is user authority**: `relaunch-add` warns about known hazard
  tokens, but a user can hand-edit a dangerous command into the file. The safety
  property is “nothing unattended,” not “nothing dangerous.”
- **Flattened argv is lossy**: `ps` cannot preserve quoted multi-word argument
  boundaries. The advisory shape filter excludes those commands instead of
  proposing a replay it cannot reproduce exactly.
- **Binary-name collisions remain possible**: Short names such as `pi`, `omp`,
  and `grok` can identify an unrelated process. Bare commands are never eligible
  for relaunch, and an exact user voucher is still required.
- **Hazard warnings are deliberately incomplete**: The `relaunch-add` list is
  advisory only. It does not participate in save or restore authorization and
  cannot silently become a maintainer-owned command allowlist.
- **First save after install (chicken-and-egg)**: An assistant must expose a
  session ID before it can be saved. Claude and OpenCode normally do this at
  session start. **A Copilot session you have not typed into yet cannot be
  restored**: Copilot only makes a session resumable once it has content, so an
  idle pane sitting at a fresh Copilot prompt comes back as a plain shell.
  Codex/OpenCode (`-s`) and Pi (`--session`) can expose IDs directly in args.
- **Claude process title**: Claude Code sets `process.title = 'claude'`, but on
  macOS arm64 (v2.1.44+) `ps -eo args=` still shows full args. CLI flags like
  `--dangerously-skip-permissions` are captured from `ps` at save time. If a
  future version hides args, `cli_args` will be empty and restore falls back to
  bare resume commands.
- **OpenCode without plugin**: If the OpenCode plugin isn't installed and the
  process was started without `-s`, the session ID cannot be detected.
- **Copilot storage contract**: Copilot support relies on the live session
  writing `session-state/<uuid>/inuse.<pid>.lock`, which is not a documented
  interface. `test/copilot-contract-test.sh` pins it against the real binary;
  explicit `--session-id`/`--resume` argv remains the fallback if it changes.
- **Copilot options with spaces in their values**: `ps` shows a flattened
  command line, so a value like `--add-dir "/tmp/My Project"` cannot be told
  apart from several arguments. Since Copilot rejects positional arguments
  outright, such options are dropped from `cli_args` rather than replayed —
  the session resumes, without that flag. Values without spaces are unaffected,
  in both `--flag value` and `--flag=value` form.
- **Copilot session names**: Copilot refuses `--name` together with `--resume`,
  so a session started with `--name` is resumed without it.
- **Copilot killed with SIGKILL**: the lock is removed on graceful exit but
  survives `kill -9`. A stale lock is rejected by comparing its mtime against
  the claiming process's start time, so a recycled PID cannot resurrect a dead
  session.
- **OpenCode DB fallback (same-cwd ambiguity)**: When the plugin state file is
  unavailable and no `-s` flag was used, the save script falls back to the
  OpenCode SQLite database, matching sessions by working directory. If multiple
  sessions share the same cwd, the most recently updated one is picked — which
  may not be the correct one for that specific pane.
- **Pi session-file fallback (same-cwd ambiguity)**: Pi session lookup is cwd-
  scoped (`~/.pi/agent/sessions/--<cwd>--`). If multiple live Pi sessions share
  a cwd and look equally recent, one pane may be matched to the wrong ID.
- **Process inspection on macOS**: Uses `ps -eo pid=,ppid=` instead of `pgrep -P`
  due to reliability issues with `pgrep` on macOS.
- **Pane matching after restore**: tmux-resurrect preserves pane indices, so the
  restore hook looks for the same session name, window index and pane index. It
  matches those three values literally against `tmux list-panes` output rather
  than handing tmux the `session:window.pane` string, because tmux's target
  grammar reserves `:` and `.` and also prefix-matches session names — a pane in
  a session called `v1.2` or `https://host/repo` would otherwise be skipped or
  resolved against a different session. The pane id that lookup returns is what
  every subsequent tmux command targets. If you manually rearrange panes between
  save and restore, the mapping may be wrong.
- **Session names containing a newline or tab**: not supported. tmux itself
  rejects both, so they cannot occur. Every other character — including `:`,
  `.` and `|` — round-trips. Note that tmux before 3.7 silently rewrote `:` and
  `.` in session names to `_`, so names that survive on 3.7 change shape on
  older versions; the sidecar records whatever tmux reports.

## License

MIT
