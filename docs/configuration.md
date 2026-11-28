# Configuration

[← Back to README](../README.md)

Most settings are tmux options in `~/.tmux.conf`; put them before TPM's `run`
line. A few are environment variables, noted where they apply.

## Native hook/plugin installers

Native hook/plugin installers are enabled by default. To disable an individual
installer, put its option before TPM's `run` line in `~/.tmux.conf`:

```tmux
set -g @assistant-resurrect-claude 'off'
set -g @assistant-resurrect-cursor 'off'
set -g @assistant-resurrect-opencode 'off'
```

Set only the options for assistants you want to disable. Reload your tmux
configuration to apply them. Claude/Cursor opt-outs remove our current and
stale hook commands while preserving unrelated hooks, settings, dotfile
symlinks and target modes. The OpenCode installer removes its own
`session-tracker.js` and `assistant-resurrect` symlinks (including stale checkout
paths) and leaves regular files, directories and unrelated symlinks alone. `on`,
or leaving the option unset, enables installation when OpenCode v1 or v2 commands
are found on tmux's `PATH`.
These options control native hook/plugin installation; they do not disable the
save/restore hooks or native-state/process-argument/database fallbacks. Hookless
assistants have no installer to opt out of.

OpenCode v1 and v2 use different plugin APIs, so each has its own tracker. The
installer checks `opencode --version` (and `opencode2`, when present) **before**
linking:

| Found on tmux's `PATH` | Installed |
|---|---|
| v1 only | `plugins/session-tracker.js` (v1 tracker) |
| v2 only, or v1 and v2 together | `plugins/assistant-resurrect` (v2 tracker) |
| A future major, an unknown/dev version, a failed probe, or no binary | Neither; both of our links are removed |

OpenCode v2 reports the v1 file as a failed plugin, so the v1 tracker is not
installed when a v2 command is visible, even beside a v1 command. In that mixed
case v1 panes fall back to the `-s` flag and the database lookup. OpenCode v1
ignores the v2 tracker, which is a directory. After installing OpenCode or
correcting tmux's `PATH`, reload the configuration to install the right tracker.
Restart OpenCode after a tracker is added or removed so running TUIs pick up the
change.

## Save location

The save hook writes `assistant-sessions.json` (and its logs) next to
tmux-resurrect's own saves, resolved exactly as resurrect resolves it:
`@resurrect-dir` if you set it, otherwise `~/.tmux/resurrect` when that
directory already exists, else the XDG default
`${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect`. Set `TMUX_RESURRECT_DIR` to
override. `just status` (from the plugin directory) prints the directory in use;
[the walkthrough](walkthrough.md#3-save) has a one-liner that mirrors the same
resolution logic.

## State directory

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
JSON (`assistant-sessions.json`, in tmux-resurrect's save directory — see
[Save location](#save-location)) is what a restore reads. Because `$HOME` survives reboots
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

## Environment variable capture and restoration

By default, the plugin captures `TMUX_PANE` and `SHELL` in hook/plugin-backed
assistant state files (Claude/Cursor/OpenCode). To capture additional environment
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

**Tools without a session hook** (Copilot, Codex, Pi, Oh My Pi, Grok, Antigravity CLI, Kiro CLI) have no state file
to capture from at launch. On **Linux and WSL**, the save hook instead reads the
configured variables straight from each detected assistant's environment via
`/proc/<pid>/environ`, so values like `CODEX_HOME` survive a restart. Only the
variables you list in `@assistant-resurrect-capture-env` are read, plus the
assistant's own state-root variable (see [State roots](#state-roots)); nothing
else is inspected. Where a value is available from both a session hook and the
live process, the live process wins.

> **Platform note:** Reading another process's environment is only possible
> unprivileged on **Linux/WSL** (`/proc`). macOS withholds it even for your own
> processes, so there hookless tools capture no env at save time. If you need a
> fixed value on macOS, export it in your shell profile (the restored pane
> inherits it) or set it globally with `tmux set-environment -g VAR value`.

## State roots

Some assistants keep their sessions in a directory that one environment
variable relocates. A session ID only means something inside the directory it
was found in, so the plugin pins that directory automatically, with no
`@assistant-resurrect-capture-env` entry needed:

| Assistant | Variable | Default |
|---|---|---|
| GitHub Copilot CLI | `COPILOT_HOME` (or `--config-dir`) | `~/.copilot` |
| Codex CLI | `CODEX_HOME` | `~/.codex` |
| OpenCode | `XDG_DATA_HOME` | `~/.local/share` |
| Grok | `GROK_HOME` | `~/.grok` |
| Kiro CLI | `KIRO_HOME` | `~/.kiro` |

On save, the directory is resolved the same way the session lookup resolves it:
the assistant process's own value (Linux/WSL, via `/proc`), then the tmux
server's environment, then the default. Only a non-default directory is
recorded (`state_root` in the sidecar), and restore prepends it to the resume
command, for example `CODEX_HOME='/work/codex' codex resume <id>`. It is a path,
not a secret, so the restore log shows it unmasked. If you also capture the same
variable, the pinned value wins and is applied once.

To let the restored pane's own environment decide instead (for example when you
moved the directory between save and restore), turn pinning off globally or per
assistant; the assistant-specific option wins:

```bash
set -g @assistant-resurrect-pin-state-root off
set -g @assistant-resurrect-codex-pin-state-root on
```

Saves written before `state_root` existed restore as before: Copilot's older
`copilot_home` field is still honored, and other assistants get no prefix.

Built-in variables (`TMUX_PANE`, `SHELL`) are **not** restored — `TMUX_PANE`
would be stale after restore, and `SHELL` is already in the environment.
State files are written atomically with mode 0600. The default state directory
is created mode 0700, and its parents (`~/.local`, `~/.local/state`) are left at
your umask. The persistent sidecar and save/restore logs are also owner-only,
and the plugin refuses to append through a symlinked log path. A state directory
that already exists keeps whatever mode you gave it — if you point
`TMUX_ASSISTANT_RESURRECT_DIR` somewhere deliberately group-readable, that is
respected rather than reset on every save.

### What happens to secrets

Two different things, and the difference matters:

**Captured environment values are stored, and masked only in the logs.** A
variable you list in `@assistant-resurrect-capture-env` has to be written to the sidecar
verbatim, because restoring it is the entire point. The save and restore logs
show `VAR=***` so that a log you paste into an issue does not carry your key,
but the sidecar JSON itself holds the real value. It is mode 0600, as are both
logs, and the plugin refuses to append through a symlinked log path — the
protection here is file permissions, not redaction.

**Credential flags on the command line are dropped, not stored.** If a pane was
launched with `--api-key`, `--token`, `--secret*`, `--password` or `--auth*`
(including `_`/`-` suffixed spellings), the flag and its value are stripped
before anything is persisted, and a `stripped credential flag(s) from ...` line
names the flag without its value. Stripping also runs on restore, so a sidecar
written by an older version is cleaned on the way out rather than replayed.

> **Known limitation:** stripping matches the flag *name*, so a secret buried
> inside an opaque value survives — `claude --settings '{"env":{"ANTHROPIC_API_KEY":...}}'`
> is persisted as written. Scanning values instead would mean guessing which
> blobs are sensitive and silently breaking legitimate restores, so the blast
> radius is bounded by file mode instead.

Prefer keeping keys in your shell profile or a secrets manager over passing them
on the command line or capturing them. State files persist to disk and may
outlive the process they were captured from.

## Excluding replayed flags and environment variables

By default, existing replay behavior is preserved. Flags and environment
variables have **separate opt-outs**. For example, to stop Claude from reusing a
launch-time model and a pane-specific settings document:

```bash
set -g @assistant-resurrect-claude-drop-flags '--model --settings'
set -g @assistant-resurrect-claude-drop-env 'ANTHROPIC_MODEL'
```

Both are needed if the original model was supplied through both CLI arguments
and `ANTHROPIC_MODEL`. Dropping only the flag still leaves the environment
variable able to override the resumed session's model; dropping only the
variable still leaves the explicit flag. A dropped `--model` also suppresses
the plugin's fallback from the sidecar `model` field.

For a policy shared by every assistant, use the global forms:

```bash
set -g @assistant-resurrect-drop-flags '--model'
set -g @assistant-resurrect-drop-env 'OLD_LAUNCH_SETTING'
```

Global and assistant-specific lists are combined; duplicates are harmless.
Assistant-specific lists add exclusions and cannot re-enable a global exclusion.
Replace `claude` in the option name with `cursor`, `copilot`, `opencode`, `codex`,
`pi`, `omp`, `grok`, `agy`, or `kiro` to scope a rule to that assistant. All lists are
whitespace-separated and empty by default.

**Flag exclusions** remove every occurrence, together with its values. They
handle `--flag value`, `--flag=value`, known short aliases, and attached short
values such as Codex's `-mopus`. Option arity and aliases are taken from the
assistant's help with pinned fallbacks for common options. Boolean flags do not
consume a prompt word; variadic flags lose all their values. Only option-shaped
names are accepted; invalid entries are logged and ignored. No glob patterns
are supported.

**Environment exclusions** win over `@assistant-resurrect-capture-env`: excluded
values are omitted from the sidecar, are not restored from older sidecars, and
are unset in the new process even if inherited from the pane shell. The parent
shell and tmux server environment are unchanged. Only valid environment variable
names are accepted. If an exclusion names the variable that holds a pinned
state root (see [State roots](#state-roots)), that pane is skipped with a
diagnostic rather than opening a different conversation; turn pinning off for
that assistant if you want the pane's own environment to decide instead.

Both policies are checked at save and restore time, so new exclusions also
apply to old saves. Removing an exclusion cannot recover a value already omitted
from a save; save a running session again to capture it. Flag exclusions affect
optional arguments of resumed sessions, not the required session selector or
exact, explicitly vouched session-less commands. Environment exclusions also
apply to session-less relaunches.

These are replay controls, not a general configuration reset. An assistant can
still obtain settings from its own configuration files, provider defaults, or
model-alias overrides. In particular, a settings file can introduce an environment
variable again after the process starts. The plugin does not rewrite JSON inside
`--settings` or alter those files. Exclude the whole `--settings` option when its
launch-time document should not be replayed.

## Restore launch prefix

To run one assistant through a wrapper on restore, set its per-tool option to
the wrapper's absolute path. The path must contain no whitespace, control
characters, `=`, `'` or `\`, and must name an executable file, not a directory.
Restore shell-quotes it and places it before the normal resume command; it is
read from the tmux option at restore time and is never stored in the sidecar.
An invalid value is logged and restore falls back to the plain command. The
prefix applies to session resumes only; vouched relaunch commands are sent as
vouched.

```bash
set -g @assistant-resurrect-claude-launch-prefix '/home/me/bin/claude-wrapper'
```

The wrapper receives the assistant command and its arguments. With a prefix,
restore no longer puts `command` in front of the assistant, so the wrapper must
end with `exec "$@"`: a script has no interactive aliases or functions, and
that reaches the real binary:

```sh
#!/bin/sh
# Set up the environment needed by Claude here.
exec "$@"
```

The option is named per tool, with the same tool names as the per-tool options
in [Excluding replayed flags and environment variables](#excluding-replayed-flags-and-environment-variables).

## Session-less relaunch vouchers

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

## PATH in restricted environments (NixOS, systemd services)

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

## Continuum save interval

Add to `~/.tmux.conf`:

```bash
set -g @continuum-save-interval '10'  # minutes (default: 5)
```

## Oh My Pi: continuing an interrupted turn

`omp --resume <id>` reopens a session; `omp --restore <id>` also goes on with
what the session's last process left unfinished -- the turn that a reboot or a
`SIGKILL` cut off, and the subagents it was running. Restore uses `--restore`
whenever the installed omp lists it in `omp --help` (18.10.x and later), and
falls back to `--resume` on older builds, when `omp --help` cannot be run from
the hook, or when the saved arguments carry something `--restore` refuses
(`--continue`, `--fork`, `--goal`, `--no-session`, an import, `--print`/`--mode`).

Continuing a turn means its pending tool calls are issued again without anyone
at the keyboard. To reopen sessions without that:

```bash
set -g @assistant-resurrect-omp-restore 'off'      # always plain --resume
```

## Restore pacing (per-pane delays)

Restore paces itself twice per assistant pane: a short settle after clearing the
pane, and a stagger between launches so a machine with many agents does not start
them all at once. Both default to the values they replace, so leaving them unset
restores exactly as before.

```bash
set -g @assistant-resurrect-clear-delay '0.3'      # seconds after clearing, before the replay
set -g @assistant-resurrect-launch-stagger '1'     # seconds between launches
```

They matter at scale, because they are paid per pane and the per-session client
wait no longer is. On a server with 38 assistant panes they account for roughly
`38 x 1.3s` of the restore. Lowering them trades startup smoothness for
wall-clock; `0` removes a delay entirely.

Non-negative decimals are accepted (`0`, `0.05`, `2.5`). Anything else falls back
to the default rather than being passed to `sleep`.

> `@assistant-resurrect-clear-delay` sits between `clear-history` and the replay,
> giving the pane a moment to settle before the resume command is sent.

## Save-hook timeout (watchdog)

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
terminated or failed save never corrupts the previously saved sessions. A save
whose session lookups were interrupted by the deadline is not published either,
even if it manages to finish: its snapshot could be missing panes, so the
previous sidecar is kept and the hook exits non-zero. (A deadline reached
earlier, while probing `<tool> --help`, only degrades flag discovery to the
built-in fallbacks; that save is still published, provided it finishes within
the grace period before the `SIGKILL` escalation.) A timeout is reported on the hook's **stderr** (surfaced wherever tmux-resurrect
captures hook output) rather than to `assistant-save.log` — writing to the log
could itself block on the same stalled filesystem that triggered the timeout.

> **Scope:** the watchdog is armed at the start of the hook's main work, so it
> covers detection and serialization (where session-lookup helpers run). A short
> prologue — reading a couple of tmux options and creating temp files — runs
> before it is armed; that is the same set of tmux/filesystem calls the hook has
> always made, and if the tmux server itself is wedged it would not have
> triggered the save in the first place.
