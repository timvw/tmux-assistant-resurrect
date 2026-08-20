# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
GitHub Copilot CLI, OpenCode, Codex CLI, Pi, Oh My Pi, Grok) across tmux
restarts. It hooks into
tmux-resurrect to save session IDs and restore them automatically.

## Architecture

- `tmux-assistant-resurrect.tmux` -- TPM plugin entry point (sets tmux options, installs hooks)
- `hooks/` -- Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/lib-detect.sh` -- Shared library: `detect_tool()`, `pane_has_assistant()`, `posix_quote()`
- `scripts/save-assistant-sessions.sh` -- Resurrect post-save hook (process detection + session IDs + enriched fields via `extract_cli_args()`)
- `scripts/restore-assistant-sessions.sh` -- Resurrect post-restore hook (resumes assistants with CLI flags + env vars)
- `config/` -- tmux configuration snippet (used by `just install`, not TPM)
- `docs/design-principles.md` -- Detection approach, session ID extraction, process title behavior
- `justfile` -- Developer recipes (install, uninstall, status, test); end users use TPM
- `test/` -- Docker-based integration tests with real CLI binaries

## Design constraints

- **No wrapper scripts**: Do not create wrapper functions/aliases around
  `claude`, `copilot`, `opencode`, `codex`, or `pi`. Use native runtime state or
  hook/plugin systems instead.
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
- **Restore shell whitelist**: Guard 1 strips a leading `-` (login shells report
  as `-bash`, `-zsh`, etc.) then checks against a hardcoded whitelist: `bash`,
  `zsh`, `fish`, `sh`, `dash`, `ksh`, `tcsh`, `csh`, `nu`. If a user's shell
  isn't in this list, restore silently skips the pane. Update the whitelist in
  `scripts/restore-assistant-sessions.sh` if needed.

## Detection approach

Agent detection uses direct process inspection: the save script takes a single
`ps -eo pid=,ppid=,args=` snapshot and matches child processes of tmux pane
shells against known assistant binary names via `detect_tool()` in
`scripts/lib-detect.sh`.

Session ID extraction uses tool-native mechanisms (state files, process args,
JSONL lookup, SQLite database) -- this is infrastructure plumbing, not heuristic
classification. Both Claude and OpenCode overwrite their process titles, but
on macOS arm64 (v2.1.44+) process args are still visible via `ps -eo args=`.
State files and database queries remain the primary extraction methods, with
process args as a reliable fallback.

## Key conventions

- All scripts use `set -euo pipefail`
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `$XDG_RUNTIME_DIR` or `$TMPDIR` + `/tmux-assistant-resurrect`)
- State files contain the full tool-provided context (merged from hook stdin /
  plugin events) plus plugin metadata (`tool`, `ppid`/`pid`, `timestamp`, `env`).
  The Claude hook merges Claude's entire SessionStart JSON; the OpenCode plugin
  captures the full Session object. The save script reads `session_id`, `model`,
  and `env` from state files and `cli_args` from `ps` process args. The restore
  script uses `cli_args` to reconstruct the original CLI invocation and restores
  user-configured env vars (from `@assistant-resurrect-capture-env`) as a command
  prefix.
- The `env` object in state files captures `TMUX_PANE` and `SHELL` by default,
  plus user-configured vars via `@assistant-resurrect-capture-env` tmux option
  (space-separated list, set in tmux.conf)
- For assistants **without** a hook/plugin (Copilot, Codex, Pi, Oh My Pi, Grok) there is
  no state file to read `env` from, so `save-assistant-sessions.sh` captures the
  configured vars directly from the live process: `read_process_env()` reads
  `/proc/<pid>/environ` (Linux/WSL only; returns `null` where `/proc` is absent,
  e.g. macOS) and `merge_process_env()` merges those over any hook-captured
  values with the **process winning**. Only vars listed in
  `@assistant-resurrect-capture-env` are read, and both call sites in the save
  script (`resolve_pane_candidates` and `emit_session`) apply the merge. macOS
  cannot read another process's env unprivileged, so hookless tools capture no
  env there — document the shell-profile / `tmux set-environment` workaround
  instead.
- Copilot exposes a PID-specific active-session signal: the live session writes
  `$COPILOT_HOME/session-state/<uuid>/inuse.<pid>.lock` (content = the same PID).
  Resolve it with a single glob — no `/proc`, no `lsof`, no platform branch, and
  it behaves the same on Linux, WSL and macOS. (Native Windows is not a host for
  this plugin at all: tmux has no Win32 port, so there is nothing to hook into.)
  `COPILOT_HOME` replaces the whole `~/.copilot` path, same convention as
  `GROK_HOME`. An in-process `/resume` can leave more
  than one valid lock for the same PID, so the newest valid lock is authoritative.
- The lock alone is not enough: it appears at TUI startup, but Copilot writes
  `<session-state>/<uuid>/session.db` only once the conversation has content,
  and only such a session is resumable (`--resume` on an empty one exits with
  "No session, task, or name matched"). The save hook gates on `session.db` so
  restore never replays a command that errors in the pane. This costs no process
  inspection: the lock already identified the directory, so the gate is a plain
  file test. Do not confuse it with `session-store.db`, which sits at the root of
  `COPILOT_HOME`, is shared by every session, and cannot identify one.
- Testing that gate unauthenticated only reaches the negative half: a container
  session never gains content, so `session.db` never appears. The contract test
  asserts that half; `run-tests.sh` touches the file to stand in for "the user
  typed something". The positive half needs a real login and is verified by
  `test/copilot-e2e-authenticated.sh`.
- Session lookup helpers may legitimately find no ID. Every `get_<tool>_session`
  command substitution in the resolver and compatibility emitter must be
  explicitly non-fatal (`|| true` inside the substitution), because a failed
  bare command-substitution assignment triggers `set -e` in supported Bash
  versions.
- Copilot accepts **zero** positional arguments, which makes flattened argv
  fatal rather than merely lossy: `--add-dir "/tmp/My Project"` reaches `ps` as
  three tokens, and replaying the tail makes Copilot exit with "too many
  arguments". `_copilot_drop_flattened_values()` drops any option whose value
  arrived split, exempting variadic options (`--allow-tool[=tools...]`), whose
  several tokens round-trip correctly. It must run *before* the session-flag
  strippers, which consume only one token and would strand the rest. Two
  non-obvious cases: after an **equals-form** option (`--name=my feature`) even a
  single trailing bare token is a lost fragment, because the `=` already bounded
  the value — and that beats the variadic exemption, since
  `--deny-tool='shell(git push)'` flattens the same way; and the word-split runs
  under `set -f`, since argv is data and `--allow-tool '*'` must not be expanded
  against the hook's cwd. If a restriction cannot be reproduced exactly, all
  Copilot replay flags are dropped and restore uses a bare resume; keeping any
  remaining grant or MCP-enablement flag could silently widen permissions.
- `--attachment` is stripped unconditionally for Copilot: restore always resumes
  interactively and Copilot refuses it there ("only supported in non-interactive
  prompt mode"). The `--prompt`/`--interactive` truncation only reaches flags
  written *after* the prompt, so position-independent stripping is required.
  Verified against 1.0.78 — `--silent`, `--share`, `--share-gist` and
  `--enable-memory` resume without complaint and are deliberately left alone.
- Two Copilot options are **hidden from `--help`** yet refused alongside
  `--resume`: `--worktree`/`-w` and `--cloud`. Flag discovery can never learn
  them, so they are stripped from a static list. Re-check that list when
  Copilot's experimental surface changes.
- The deprecated `--config-dir <path>` relocates the whole state root per
  process (verified on 1.0.78: the lock lands there and nothing under
  `~/.copilot`), so `copilot_session_state_dir()` takes the candidate's argv and
  prefers it over `COPILOT_HOME`. The resolved root is saved as `copilot_home`
  and restored through `COPILOT_HOME`, including paths whose quoting `ps`
  flattened and process-only values read from `/proc`.
- Discovery caches live in shell variables and every caller runs inside a `$()`
  subshell, so a cache written there is discarded. `_warm_session_discovery()`
  must therefore call `_tool_help` **directly** in the parent shell, and any new
  helper that parses `--help` needs a `SESSION_EXTRA_WARM_<tool>` entry.
  Otherwise `<tool> --help` re-execs once per pane on every save.
- Log files go to `assistant-{save,restore}.log` in tmux-resurrect's save dir
  (resolved by `resurrect_data_dir` in `lib-detect.sh`; truncated to 500 lines per run)
- Process inspection uses `ps -eo pid=,ppid=` (not `pgrep -P` -- unreliable on macOS)
- Agent detection matches binary names via `case` patterns in `detect_tool()`
- Hook install uses two-phase matching: **exact equality** (`== $cmd`) to detect
  whether the current-path hook is already installed, and **substring match**
  (`contains("claude-session-track")`) to clean up stale copies left by path
  changes (e.g., Nix rebuilds). Cleanup runs when the current hook is missing OR
  stale copies exist. The `// ""` null-coalescing on `.command` prevents crashes
  on hook entries that lack a `.command` field (e.g., URL-type hooks), and
  `.hooks` is null-coalesced before mapping to handle entries with missing/null
  hooks arrays
- Hook commands for a plugin installed under `$HOME` are persisted as
  `bash "$HOME"'/rest/of/path.sh'`, not as the expanded path. `settings.json` is
  commonly tracked in a dotfiles repo, and an expanded path embeds `$HOME`, which
  differs across machines -- different usernames, and `/Users` vs `/home` between
  macOS and Linux -- so the two-phase matching rewrites it on every tmux start.
  Only `$HOME` sits in double quotes; the remainder is single-quoted and adjacent,
  so the shell concatenates them and a `$`, backtick, `$(...)` or `"` in the
  install path stays literal. A naive `bash "$HOME/..."` would execute it.
  Installs outside `$HOME` (Nix store, system-wide) have no portable prefix and
  keep the single-quoted absolute path; both forms therefore share exactly one
  limitation, a single quote in the install path (unlikely with TPM).
  Substituting only `$HOME` is deliberate -- it is the one
  variable guaranteed to be set in the hook's environment (Claude Code resolved
  `~/.claude/settings.json` through it), and a second candidate prefix such as
  `$XDG_CONFIG_HOME` would make the stored value depend on which machine ran the
  install, reintroducing the churn
- Use `posix_quote()` from `lib-detect.sh` for values sent to POSIX-ish/fish
  panes. When the pane shell is known and csh/tcsh is supported, use
  `shell_quote()` so history expansion and embedded quotes remain literal.
- The sidecar JSON (`assistant-sessions.json`) entries include enriched fields:
  `model` (from state file or `--model` in args), `cli_args` (from `ps` args
  with binary name and session/resume args stripped), `env` (from state file),
  and `copilot_home` for Copilot's resolved state root. All are optional for
  backward compatibility.
- `extract_cli_args()` in `save-assistant-sessions.sh` strips per-tool session
  args: Claude `--resume[= ]<id>`, Copilot session selectors (including
  `--name`, which Copilot refuses to combine with `--resume`) and initial-prompt
  `--prompt`/`--interactive` plus trailing argv, OpenCode `--session[= ]<id>` and `-s <id>`,
  Codex `resume <id>`, Pi `--session[= ]<id>`, Grok `--resume`/`-r`/`--session-id`/
  `--continue`. Returns normalized whitespace-trimmed string. (Grok's restore
  ignores the result — see `restore-assistant-sessions.sh` — but the field is
  still populated for the sidecar JSON.)
- The restore script only restores env vars listed in
  `@assistant-resurrect-capture-env` (not `tmux_pane` or `shell`), prepended
  as `VAR='val'` prefix to the resume command

## Upstream assumptions to verify

These assumptions were derived from reading upstream source code. If behavior
changes after an upgrade, check the relevant source to confirm.

| Assumption | Why it matters | Where to verify |
|-----------|---------------|----------------|
| **Claude sets `process.title = 'claude'`** | Node.js sets the process title, but on macOS arm64 (v2.1.44) `ps -eo args=` still shows full args (e.g., `claude --dangerously-skip-permissions`). The save script's `extract_cli_args()` relies on this. If a future version hides args, `cli_args` will be empty and restore falls back to bare `<binary> <resume_arg>`. | Run `ps -eo args=` on a running Claude process; Claude Code source: search for `process.title` |
| **Copilot writes `<session-state>/<uuid>/inuse.<pid>.lock`** | Primary PID-to-session mapping for bare launches and in-process `/resume`; avoids same-cwd ambiguity and stale npm-loader argv. Undocumented upstream, hence the contract test | `test/copilot-contract-test.sh` asserts it against the real binary; manually, `ls ~/.copilot/session-state/*/inuse.*.lock` while Copilot runs |
| **Claude hook spawns intermediate `sh -c`** | `$PPID` in the hook is NOT Claude's PID; hooks walk the process tree via `find_claude_pid()` (max 5 levels) | Run `ps -eo pid=,ppid=,args=` while a hook is executing |
| **OpenCode plugins run in-process** | `process.pid` in the plugin IS the opencode binary's PID; state file is keyed by this PID | OpenCode source: search for `await import(` in the plugin loader (approx. `packages/opencode/src/plugin/index.ts` -- path may move) |
| **OpenCode Go binary overwrites process title** | `-s <id>` is NOT visible in `ps`; plugin state file or SQLite DB are the reliable sources | Run `ps -eo args=` on a running `opencode -s <id>` process |
| **OpenCode SQLite DB** at `~/.local/share/opencode/opencode.db` | Fallback session ID extraction when plugin state file and args are unavailable; matches by cwd + most recent `time_updated` | Check DB schema: `sqlite3 ~/.local/share/opencode/opencode.db ".schema session"` |
| **Codex may write `~/.codex/session-tags.jsonl` and publishes its UUID in the tmux pane title** | PID tags are preferred when present; the pane title disambiguates bare sessions sharing a cwd before database fallback | Run Codex and compare its pane title, process PID, and `~/.codex/session-tags.jsonl` when present |
| **Pi session files live in `~/.pi/agent/sessions/--<cwd>--/*.jsonl`** | Primary session ID source for Pi when `--session` is absent in args; save script reads header `type=id/cwd/timestamp` and scores candidates by process lifetime + mtime | Run Pi and inspect `~/.pi/agent/sessions`, verify first JSONL line has `{"type":"session","id":"..."}` |
| **grok writes `~/.grok/active_sessions.json`** | Primary session ID source for Grok: an array of `{session_id, pid, cwd, opened_at}` for every live session, updated on open/close. `get_grok_session()` looks up by PID (works even for a bare `grok` with no args); `-r`/`--resume <uuid>` in process args is the fallback. `GROK_HOME` overrides the `~/.grok` base. | Run `grok`, then `cat ~/.grok/active_sessions.json`; confirm each running `grok` PID appears with its `session_id` |
| **tmux-resurrect pane content archive** layout: `./pane_contents/pane-{session}:{window}.{pane}` inside `pane_contents.tar.gz` | `strip_assistant_pane_contents()` removes assistant pane files from this archive to prevent stale TUI flash on restore | tmux-resurrect source: `scripts/helpers.sh:pane_contents_file()` |

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
| **`process.title` vs `ps` args** | Claude Code sets `process.title = 'claude'` (Node.js), but `ps -eo args=` still shows full command line on macOS arm64 v2.1.44. This may not hold on Linux or future versions. `extract_cli_args()` degrades gracefully to empty string |
| **Claude `permission_mode` not in SessionStart hooks** | Claude Code v2.1.44 passes `undefined` for `permission_mode` in `executeSessionStartHooks`. The save script works around this by extracting `--dangerously-skip-permissions` from `ps` args via `extract_cli_args()` |

## Testing

Tests run in Docker with real CLI binaries (`@anthropic-ai/claude-code`,
`@github/copilot`, `opencode-ai`, `@openai/codex`,
`@earendil-works/pi-coding-agent`). No API keys are needed.

Copilot is covered at three layers, because a hermetic test that fabricates the
artifact it then looks for cannot notice upstream changing the layout:

| Layer | File | Catches |
|-------|------|---------|
| Contract | `test/copilot-contract-test.sh` | upstream changing the on-disk contract we depend on |
| End-to-end | `test/run-tests.sh` Test 2/3, real binary | save/restore wiring against reality |
| Hermetic | `test/copilot-unit-tests.sh` | lock integrity, stale locks, argv fallback, `extract_cli_args` |
| Authenticated | `test/copilot-e2e-authenticated.sh` | whether a real conversation actually comes back |

**Run the authenticated test after touching Copilot session discovery**
(`GH_TOKEN=$(gh auth token) just test-copilot-e2e`). It is the only layer that
can tell a resumable session from an unresumable one: unauthenticated Copilot
still creates a session directory and lock, so a lookup returning a UUID that
`--resume` rejects looks exactly like a correct one. That blind spot already
shipped one bug. It cannot run in CI — fork pull requests cannot read secrets.

The contract and end-to-end layers need **no authentication**: Copilot creates
the session directory and its lock before the auth check runs. Launch it in the
integration test with *no* session selector, so the UUID exists only in the lock
and a regressed lookup cannot be masked by the argv fallback.

CI covers three platforms. The Docker suites (bash 5 and bash 3.2) run on Linux;
a `macos-latest` job runs the hermetic suites plus the real-binary Copilot
contract suite, because every BSD path — `stat -f`, the `ps -o etime=`
process-start fallback, and the flattened-argv heuristic that exists only
because `/proc/<pid>/cmdline` is unavailable — is otherwise exercised nowhere but
a contributor's laptop; and a `windows-latest` canary runs the hermetic suites
under Git Bash to catch Linux-isms, without implying Windows is supported.

```bash
# Run the full test suite in Docker
just test

# Manual debugging on a live system
just save                          # trigger a save manually
just status                        # check installation status
just clean                         # remove stale state files
cat ~/.local/share/tmux/resurrect/assistant-sessions.json | jq .   # XDG default; see resurrect_data_dir
cat ~/.local/share/tmux/resurrect/assistant-save.log
cat ~/.local/share/tmux/resurrect/assistant-restore.log
```

### Test infrastructure notes

- The save script has a `main()` guard so tests can `source` it to call
  extraction functions directly without executing the full save flow.
- Tests use polling helpers (`wait_for_child`, `wait_for_descendant`,
  `wait_for_death`) instead of fixed `sleep` -- fast on fast machines,
  tolerant on slow CI.
- `kill_pane_children()` does tree-walk cleanup instead of inline kill patterns.
- npm packages are pinned to major versions: `claude-code@^2`,
  `@github/copilot@^1`, `codex@^0`, `opencode-ai@^1`, `pi-coding-agent@^0`.

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
