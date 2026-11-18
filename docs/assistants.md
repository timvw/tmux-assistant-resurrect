# Supported assistants

[← Back to README](../README.md)

How each assistant is detected, how its session ID is found, and how it is resumed.

## Session ID extraction

Detection is done via direct process inspection: the save script takes a
single `ps` snapshot of all processes, finds children of each tmux pane shell,
and matches known assistant binary names (`claude`, `agent`/`cursor-agent`,
`copilot`, `opencode`, `codex`, `pi`, `omp`, `grok`, `agy`, `kiro-cli`).

Session ID extraction uses tool-native mechanisms (infrastructure plumbing):

| Tool | Primary method | Fallback 1 | Fallback 2 | Notes |
|------|---------------|------------|------------|-------|
| **Claude Code** | `SessionStart` hook state file (keyed by Claude PID) | `--resume` / `--session-id` in process args | Newest non-empty cwd-scoped transcript under `~/.claude/projects/` | Transcript lookup excludes IDs reserved by PID-specific state/argv and already emitted for another pane, but two unresolved Claude instances in one cwd remain ambiguous and an abandoned session can be selected |
| **Cursor Agent CLI** | `sessionStart` hook state file (keyed by Cursor PID) | `--resume` in process args | - | Supports both the current `agent` and compatibility `cursor-agent` executable names; desktop Cursor hook events are ignored |
| **GitHub Copilot CLI** | `$COPILOT_HOME/session-state/<uuid>/inuse.<pid>.lock` written by the live session | `--session-id` / `--resume` in process args | - | Plain glob keyed on the native PID — no `/proc`, no `lsof`, so it behaves identically on Linux, WSL and macOS |
| **OpenCode** | `-s` / `--session` in process args | Plugin state file | SQLite DB query (`$XDG_DATA_HOME/opencode/opencode.db`, default `~/.local/share`) | Go binary overwrites process title; DB fallback matches most recent session by cwd |
| **Codex CLI** | PID lookup in `~/.codex/session-tags.jsonl` | `resume` in process args | SQLite `~/.codex/state_*.sqlite` `threads` table (Codex >= 0.118); rollout JSONL `~/.codex/sessions/` (Codex ~0.100-0.117) | Codex runs via Node.js, so args are always visible in `ps` |
| **Pi** | Session header lookup in `~/.pi/agent/sessions/--<cwd>--/*.jsonl` | `--session` in process args | - | Session-file lookup is cwd-scoped and uses process-time scoring + dedup |
| **Oh My Pi** | Terminal breadcrumb + session JSONL lookup (`$XDG_STATE_HOME/omp`, `$XDG_DATA_HOME/omp`) | `--resume` / `-r` / `--restore` in process args | `--session-dir` / `--profile` scoped lookup | Distinct `omp` tool; no hook/plugin required. Restored with `--restore` when the installed omp lists it (18.10.x and later), otherwise `--resume` |
| **Antigravity CLI (`agy`)** | PID-owned CLI log | `--conversation <UUID>` in process args | - | No cwd/newest-session guessing; log format is an observed contract |
| **Grok** | PID lookup in `~/.grok/active_sessions.json` | `-r` / `--resume <uuid>` in process args | - | Registry records every live session (including a bare `grok` with no args) keyed by PID, so sessions sharing a cwd never collide; no hook/plugin required |
| **Kiro CLI** | Session lock (`$KIRO_HOME`, default `~/.kiro`) whose `pid` is a live descendant of the pane's `kiro-cli`: `sessions/cli/<uuid>.lock` (default TUI, v2 engine) or `sessions/<workspace-hash>/sess_<uuid>/.lock` (`--v3`) | `--resume-id <id>` in process args | - | The lock is held by a descendant, not `kiro-cli` itself (`kiro-cli-chat acp` in the default TUI, the `bun` TUI process with `--v3`), so the match walks the process tree; stale locks from killed sessions are ignored. Restore runs `kiro-cli chat --resume-id <id>` for both layouts (a `sess_` ID selects the v3 engine) without replaying flags. Verified with kiro-cli 2.22.0 on Linux; `--classic`/`--legacy-ui` is not supported (see [Limitations](troubleshooting.md#limitations)) |

Each tool has a primary and fallback extraction method. Fallbacks address the
chicken-and-egg problem: after a restore, session IDs are in process args even
before hooks/plugins have fired. The OpenCode SQLite database fallback provides
version-resilient session ID extraction even when the plugin hasn't fired.

## Antigravity CLI (`agy`)

Antigravity CLI is resumed with `agy --conversation <UUID>`. Save reads the
log file opened by the owning PID (`/proc/<pid>/fd` on Linux, `lsof` on macOS),
including an explicit `--log-file`, and tracks conversation-selection events.
An in-TUI switch overrides the original `--conversation` argument; opening a
new empty conversation clears the old selection. If no selection event exists,
only an explicit UUID in launch arguments is used. There is no cwd/newest-session
fallback, so unresolved or empty conversations are skipped.

This depends on the observed CLI log messages (`Streaming conversation`,
`Starting conversation update stream`, and full-redraw events), not a public
hook API. Changes in agy's logging may require an update. Model, effort and
permission options are retained; initial prompts and the old process log path
are not replayed. Relative log paths are resolved against the owning process's
cwd. Linux uses exact argv boundaries and omits whole options whose values
contain whitespace, which the replay sidecar cannot represent. Other platforms
use flattened argv; the discarded log path is consumed completely so its tail
does not truncate subsequent options such as `--sandbox`.
No launch wrapper or new hook is installed.

## Claude Code hooks (`hooks/claude-session-track.sh`, `hooks/claude-session-cleanup.sh`)

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

## Cursor Agent CLI hooks (`hooks/cursor-session-track.sh`, `hooks/cursor-session-cleanup.sh`)

Cursor's user-level `sessionStart` hook provides a stable `session_id` (the
conversation ID used by `--resume`). The tracking hook preserves the complete
hook payload, captures configured environment variables, and writes
`cursor-<PID>.json`. Its ancestry check accepts the current `agent` executable
and the legacy-compatible `cursor-agent` name, but deliberately writes nothing
for hook events coming from Cursor Desktop. `sessionEnd` removes the state file;
the save hook also reaps crash leftovers.

The installed Cursor launcher injects `--use-system-ca <package>/index.js` into
its visible process argv. Those runtime-only arguments are removed before
replay; user-facing options such as `--mode`, `--model`, `--sandbox`, and
`--force` are retained, while session selectors, credentials, and an initial
prompt are not replayed. Restore reuses whichever supported executable name was
observed (`agent` or `cursor-agent`) and passes `--resume <session-id>`.

## OpenCode plugin (`hooks/opencode-session-track.js`)

An OpenCode v1 plugin that listens for `session.created`, `session.updated`, and
`session.idle` events. On each event, it captures the full session object
(including model, title, and other metadata) along with init-time context
(`process.argv`, client API surface) and writes it to
`$STATE_DIR/opencode-<PID>.json`. This handles the case where
a user switches sessions at runtime (via `/sessions` or `Ctrl+x l`). The plugin
also cleans up its state file on process exit (SIGINT, SIGTERM).

## OpenCode v2 plugin (`hooks/opencode2/tui.js`)

OpenCode v2 runs one background server for every TUI, so a server plugin cannot
tell which pane shows which session. The v2 tracker is therefore a TUI plugin:
it runs inside the `opencode` process in the pane, whose PID is the one the save
hook finds. It writes the same `$STATE_DIR/opencode-<PID>.json` file as the v1
plugin, naming the session that TUI currently shows.

- Switching tabs or opening another session emits no server event, so the plugin
  checks the displayed session once a second as well as on every server event.
- On the home screen, or on an archived session, it removes its file, and the
  save hook falls back to the `-s` flag and the database lookup.
- While a subagent's session is displayed, the file names its top-level session.
- It removes its file when the TUI exits.

A TUI with several session tabs records the tab in view. Restore reopens that
session; the other tabs are not reopened.

## Codex CLI

Codex natively writes PID-to-session mappings in
`~/.codex/session-tags.jsonl`. The save script reads this file directly -- no
additional hook is needed. `CODEX_HOME` replaces the whole `~/.codex` path, the
same way `COPILOT_HOME` and `GROK_HOME` do: on Linux/WSL the save hook reads the
Codex process's own value from `/proc`; on macOS, set it for tmux too
(`tmux set-environment -g CODEX_HOME ...`).

## GitHub Copilot CLI

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

## Pi

Pi stores sessions as JSONL files under `~/.pi/agent/sessions/--<cwd>--/`.
The save hook reads session headers (`type: "session"`, `id`, `cwd`,
`timestamp`) and scores candidates by process lifetime + file mtime, with
dedup across panes. If a pane was launched via restore, `--session <id>` in
process args is used as a direct fallback.

## Adding support for a new assistant

The step-by-step checklist (detection, session lookup, state-root pinning,
restore command, hooks, tests and docs) lives in
[AGENTS.md](../AGENTS.md#adding-a-new-assistant).
