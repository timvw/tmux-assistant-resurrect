# Architecture

[← Back to README](../README.md)

For the reasoning behind these choices, see [design principles](design-principles.md).

## How it works

```
SAVE (every 5 min + manual prefix+Ctrl-s)
  tmux-resurrect saves pane layouts
    -> post-save hook inspects child processes of each pane
    -> detects assistants by binary name (claude, agent/cursor-agent, copilot, opencode, codex, pi, omp, grok, agy, kiro-cli)
    -> extracts session IDs via native hooks/plugins/process args
    -> writes assistant-sessions.json in tmux-resurrect's save dir

RESTORE (on tmux start or manual prefix+Ctrl-r)
  tmux-resurrect restores pane layouts
    -> post-restore hook reads assistant-sessions.json
    -> reconstructs full CLI invocation with saved flags + env vars
    -> sends resume commands to each pane, e.g.:
         ANTHROPIC_BASE_URL='...' claude --dangerously-skip-permissions --resume <id>
         agent --mode plan --resume <session-id>
         copilot --allow-all --resume=<id>
         opencode --verbose -s <session-id>
         codex --full-auto resume <session-id>
         pi --model sonnet --session <session-id>
         omp --profile work --restore <session-id>
         grok --resume <session-id>
         kiro-cli chat --resume-id <session-id>
         agy --conversation <session-id>
```

## Save hook (`scripts/save-assistant-sessions.sh`)

Runs after each tmux-resurrect save. Takes a single `ps` snapshot of all
processes, finds children of each tmux pane's shell, and detects assistants by
matching binary names. Then extracts session IDs using tool-specific methods
(state files, process args, JSONL lookup, session-file lookup). Also captures:

- **CLI flags** (`cli_args`): extracted from `ps` args with the binary name and
  session/resume args stripped (e.g., `--dangerously-skip-permissions --model opus`)
- **Model** (`model`): from state file (preferred) or `--model` in args (fallback)
- **Environment** (`env`): from state file (captured by hooks/plugins)
- **State root** (`state_root`): the non-default `COPILOT_HOME`/`--config-dir`,
  `CODEX_HOME`, `XDG_DATA_HOME` (OpenCode), `GROK_HOME` or `KIRO_HOME` directory
  the session was found in, replayed automatically so restore finds the same ID (see
  [State roots](configuration.md#state-roots)). Older saves may carry Copilot's as `copilot_home`

Writes everything to `assistant-sessions.json` in tmux-resurrect's save
directory (see [Save location](configuration.md#save-location)). Vouched session-less modes are written
to the sibling `.relaunch` array; ordinary resumable entries retain the existing
`.sessions` schema.

Helper programs (SQLite/JSONL lookups, path resolution) live as standalone
files under `scripts/py/` and are handed to `python3` via argv. They are
deliberately **not** embedded as shell heredocs: on bash ≥ 5.1 a heredoc is
written to a pipe before its reader is exec'd, and on macOS under pipe-memory
pressure that write can block forever, hanging the hook (issue #48). A watchdog
(see [Save-hook timeout](configuration.md#save-hook-timeout-watchdog)) bounds the detection/serialization phase as a
second line of defense.

## Restore hook (`scripts/restore-assistant-sessions.sh`)

Runs after each tmux-resurrect restore. Reads the sidecar JSON and reconstructs
the full CLI invocation for each assistant: `<env_prefix> <binary> <cli_args>
<resume_arg>`. Sends the command to each pane via `tmux send-keys`. If enriched
fields are missing (old-format JSON), falls back to bare resume commands. For a
`.relaunch` entry, it instead requires an exact current voucher match and builds
the command from the matching voucher line.

## Repository structure

```
tmux-assistant-resurrect.tmux     # TPM plugin entry point
config/
  resurrect-assistants.conf       # tmux config reference template (not sourced automatically)
hooks/
  lib-claude-pid.sh               # Shared helper: walks process tree to find Claude PID
  claude-session-track.sh         # Claude SessionStart hook (writes session ID)
  claude-session-cleanup.sh       # Claude SessionEnd hook (removes state file)
  lib-cursor-pid.sh               # Finds a Cursor Agent CLI ancestor (not Cursor Desktop)
  cursor-session-track.sh         # Cursor sessionStart hook (writes session ID)
  cursor-session-cleanup.sh       # Cursor sessionEnd hook (removes state file)
  opencode-session-track.js       # OpenCode v1 plugin (tracks session ID + cleanup)
  opencode2/tui.js                # OpenCode v2 TUI plugin (tracks the session each TUI shows)
scripts/
  lib-detect.sh                   # Shared library (detect_tool, pane_has_assistant, posix_quote)
  lib-detect.awk                  # AWK detect_tool() used by the save hook's process walk
  lib-replay.sh                   # Replay policy: drop-flags/drop-env, state-root pinning
  lib-fs.sh                       # Safe in-place updates of user-owned config files
  lib-log.sh                      # Owner-only, rotated save/restore logs
  save-assistant-sessions.sh      # Resurrect post-save hook (process detection + session IDs)
  save-assistant-sessions.awk     # Walks the ps snapshot per pane, emits assistant candidates
  restore-assistant-sessions.sh   # Resurrect post-restore hook (resumes assistants)
  py/                             # Helper programs invoked by the save hook via argv
                                  #   (never via shell heredocs — see issue #48)
test/
  Dockerfile                      # Docker image with tmux, jq, just, and real assistant CLIs
  bench-save-hook.sh              # Single-scenario save-hook benchmark runner (inside Docker)
  bench-matrix.sh                 # Docker benchmark matrix + CSV/Markdown summary generator
  run-tests.sh                    # Integration test suite
  *-unit-tests.sh, *-contract-*   # Hermetic unit suites and per-assistant contract tests
justfile                          # Install/uninstall/status/save/restore/test recipes
```
