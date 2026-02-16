# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
OpenCode, Codex CLI) across tmux restarts. It hooks into tmux-resurrect to save
session IDs and restore them automatically.

## Architecture

- `tmux-assistant-resurrect.tmux` -- TPM plugin entry point (sets tmux options, installs hooks)
- `hooks/` -- Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/lib-detect.sh` -- Shared library: `detect_tool()`, `pane_has_assistant()`, `posix_quote()`
- `scripts/save-assistant-sessions.sh` -- Resurrect post-save hook (process detection + session IDs)
- `scripts/restore-assistant-sessions.sh` -- Resurrect post-restore hook (resumes assistants)
- `config/` -- tmux configuration snippet (used by `just install`, not TPM)
- `docs/design-principles.md` -- Detection approach, session ID extraction, process title behavior
- `justfile` -- Developer recipes (install, uninstall, status, test); end users use TPM
- `test/` -- Docker-based integration tests with real CLI binaries

## Design constraints

- **No wrapper scripts**: Do not create wrapper functions/aliases around `claude`,
  `opencode`, or `codex`. Use native hook/plugin systems instead.
- **Restore hook is the sole launcher**: Assistants must NOT be listed in
  `@resurrect-processes`. The post-restore hook handles all resuming with correct
  session IDs. Adding them to `@resurrect-processes` causes double-launch.
- **TPM-only installation for end users**: Users install via TPM (`set -g @plugin
  'timvw/tmux-assistant-resurrect'` + `prefix + I`). The `justfile` recipes are
  for developers only.
- **Pipe delimiter in tmux format output**: tmux 3.4 converts tabs and control
  characters in `-F` output. Use `|` as delimiter (documented limitation: paths
  containing `|` will break, but `|` is extremely rare in directory names).
- **Two-guard restore**: The restore script has two independent guards before
  injecting a resume command into a pane: (1) the pane's foreground process must
  be a known shell, and (2) the pane must not already have a running assistant
  in its process tree. Both must pass. This prevents typing into TUIs or
  double-launching.
- **Restore shell whitelist**: Guard 1 checks `pane_current_command` against a
  hardcoded whitelist: `bash`, `zsh`, `fish`, `sh`, `dash`, `ksh`, `tcsh`,
  `csh`, `nu`. If a user's shell isn't in this list, restore silently skips the
  pane. Update the whitelist in `scripts/restore-assistant-sessions.sh` if needed.

## Detection approach

Agent detection uses direct process inspection: the save script takes a single
`ps -eo pid=,ppid=,args=` snapshot and matches child processes of tmux pane
shells against known assistant binary names via `detect_tool()` in
`scripts/lib-detect.sh`.

Session ID extraction uses tool-native mechanisms (state files, process args,
JSONL lookup, SQLite database) -- this is infrastructure plumbing, not heuristic
classification. Both Claude and OpenCode overwrite their process titles, so
process args are unreliable; state files and database queries are the primary
extraction methods.

## Key conventions

- All scripts use `set -euo pipefail`
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `$XDG_RUNTIME_DIR` or `$TMPDIR` + `/tmux-assistant-resurrect`)
- Log files go to `~/.tmux/resurrect/assistant-{save,restore}.log` (truncated to 500 lines per run)
- Process inspection uses `ps -eo pid=,ppid=` (not `pgrep -P` -- unreliable on macOS)
- Agent detection matches binary names via `case` patterns in `detect_tool()`
- Hook matching in jq uses `contains("claude-session-track")` (not exact `==`)
  to tolerate quoting changes across versions and ensure backward compatibility
- Use `posix_quote()` from `lib-detect.sh` for any values sent to tmux panes
  via `send-keys` (safe for bash, zsh, fish, and other POSIX-ish shells)
- Hook command paths use single quotes (`bash '${CURRENT_DIR}/hooks/...'`);
  this breaks if the install path contains a single quote (unlikely with TPM)

## Upstream assumptions to verify

These assumptions were derived from reading upstream source code. If behavior
changes after an upgrade, check the relevant source to confirm.

| Assumption | Why it matters | Where to verify |
|-----------|---------------|----------------|
| **Claude overwrites process title** (`process.title = 'claude'`) | `--resume <id>` is NOT visible in `ps`; state file is the only reliable session ID source | Claude Code source: search for `process.title` |
| **Claude hook spawns intermediate `sh -c`** | `$PPID` in the hook is NOT Claude's PID; hooks walk the process tree via `find_claude_pid()` (max 5 levels) | Run `ps -eo pid=,ppid=,args=` while a hook is executing |
| **OpenCode plugins run in-process** | `process.pid` in the plugin IS the opencode binary's PID; state file is keyed by this PID | OpenCode source: search for `await import(` in the plugin loader (approx. `packages/opencode/src/plugin/index.ts` -- path may move) |
| **OpenCode Go binary overwrites process title** | `-s <id>` is NOT visible in `ps`; plugin state file or SQLite DB are the reliable sources | Run `ps -eo args=` on a running `opencode -s <id>` process |
| **OpenCode SQLite DB** at `~/.local/share/opencode/opencode.db` | Fallback session ID extraction when plugin state file and args are unavailable; matches by cwd + most recent `time_updated` | Check DB schema: `sqlite3 ~/.local/share/opencode/opencode.db ".schema session"` |
| **Codex writes `~/.codex/session-tags.jsonl`** | Primary session ID source for Codex (PID → session mapping) | Run Codex and check `cat ~/.codex/session-tags.jsonl` |

## Platform gotchas

These are hard-won lessons. Do not "simplify" them away.

| Gotcha | Details |
|--------|---------|
| **macOS `pgrep -P` is unreliable** | Silently misses child processes. Always use `ps -eo pid=,ppid=` with awk |
| **tmux 3.4 mangles delimiters** | Converts tabs to underscores, control characters to octal escapes in `-F` output. Use `|` (plain pipe) as delimiter |
| **`printf %q` breaks fish shell** | Not POSIX. Use `posix_quote()` (single-quote wrapping with `'\''` escaping) instead |
| **`\|\| continue` inside `$()` runs in the subshell** | `continue` executes but only affects the subshell, not the outer loop. Place `\|\| continue` outside the `$()` |
| **`kill -0 0` succeeds** | Checks current process group, not PID 0. Always validate PIDs are numeric and > 1 before `kill -0` |
| **npx wrapper chains** | `npx opencode` spawns npm → sh → node → opencode (4+ levels). Use `wait_for_descendant()` (full tree walk) not `wait_for_child()` (direct children only) |
| **`tmux-resurrect execute_hook()` uses `eval`** | Hook stdout goes to the active pane. Log to stderr only |

## Testing

Tests run in Docker with real CLI binaries (`@anthropic-ai/claude-code`,
`opencode-ai`, `@openai/codex`). No mocks, no API keys needed.

```bash
# Run the full test suite in Docker
just test

# Manual debugging on a live system
just save                          # trigger a save manually
just status                        # check installation status
just clean                         # remove stale state files
cat ~/.tmux/resurrect/assistant-sessions.json | jq .
cat ~/.tmux/resurrect/assistant-save.log
cat ~/.tmux/resurrect/assistant-restore.log
```

### Test infrastructure notes

- The save script has a `main()` guard so tests can `source` it to call
  extraction functions directly without executing the full save flow.
- Tests use polling helpers (`wait_for_child`, `wait_for_descendant`,
  `wait_for_death`) instead of fixed `sleep` -- fast on fast machines,
  tolerant on slow CI.
- `kill_pane_children()` does tree-walk cleanup instead of inline kill patterns.
- npm packages are pinned to major versions: `claude-code@^2`, `codex@^0`,
  `opencode-ai@^1`.

## Adding a new assistant

1. Add a `case` pattern in `detect_tool()` in `scripts/lib-detect.sh`
2. Add a `get_<tool>_session()` function in `scripts/save-assistant-sessions.sh`
3. Add a restore command in `scripts/restore-assistant-sessions.sh`
4. Optionally add a hook/plugin in `hooks/` if the tool doesn't expose session IDs externally
5. Update install/uninstall recipes in `justfile` and `tmux-assistant-resurrect.tmux` if a new hook was added
6. Add tests in `test/run-tests.sh`

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add support for <tool>`
- `fix: handle <edge case>`
- `docs: update README`
