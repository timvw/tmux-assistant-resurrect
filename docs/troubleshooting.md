# Troubleshooting and limitations

[← Back to README](../README.md)

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Save finds 0 sessions | Run `ps -eo pid= -o ppid= -o args= \| grep -E 'claude\|copilot\|opencode\|codex\|pi\|omp\|grok\|kiro-cli'` to verify assistants are running |
| Session ID missing for Claude | Verify the hook is installed: `jq '.hooks.SessionStart' ~/.claude/settings.json` |
| Session ID missing, hook *is* installed | Check `assistant-save.log` — a `no session ID available` line names the state file it looked for. If that directory is empty but `ls ~/.local/state/tmux-assistant-resurrect` elsewhere is not, the two sides disagree on the path; see [State directory](configuration.md#state-directory) |
| Session ID missing for Copilot | Check `ls ~/.copilot/session-state/*/inuse.*.lock` — the number in the filename must be the native Copilot PID from `ps`. If you set `COPILOT_HOME`, the save hook must see it too (tmux hooks do not inherit your shell profile; use `tmux set-environment -g COPILOT_HOME ...`) |
| Session ID missing for OpenCode | Launch with `-s <id>`, or verify the plugin: `ls ~/.config/opencode/plugins/session-tracker.js`. The DB fallback follows `XDG_DATA_HOME` (default `~/.local/share`); on macOS set it for tmux too (`tmux set-environment -g XDG_DATA_HOME ...`) |
| Session ID missing for Codex | Verify `session-tags.jsonl` under `CODEX_HOME` (default `~/.codex`) lists your Codex PID. If you set `CODEX_HOME`, the save hook reads it from the process on Linux/WSL; on macOS set it for tmux too (`tmux set-environment -g CODEX_HOME ...`) |
| Session ID missing for Pi | Verify session files exist under `~/.pi/agent/sessions/--<cwd>--/*.jsonl` and that pane cwd matches the Pi session cwd |
| Session ID missing for Grok | Verify `~/.grok/active_sessions.json` exists and contains an entry with your Grok process's PID: `jq '.[] | select(.pid == <PID>)' ~/.grok/active_sessions.json`. If you set `GROK_HOME`, the save hook reads it from the Grok process on Linux/WSL; on macOS set it for tmux too (`tmux set-environment -g GROK_HOME ...`) |
| Session ID missing for Kiro CLI | Find the lock-holding PID under the pane (`ps -eo pid,ppid,args`): `kiro-cli-chat acp` in the default TUI, the `bun` TUI process with `--v3`. Check it appears in a lock: `grep -l '"pid":<PID>,' "${KIRO_HOME:-$HOME/.kiro}"/sessions/cli/*.lock "${KIRO_HOME:-$HOME/.kiro}"/sessions/*/sess_*/.lock` (use the Kiro process's `KIRO_HOME` if your shell does not have it). The matching metadata (`cli/<uuid>.json` or `sess_<uuid>/session.json`) must exist too. If you set `KIRO_HOME`, the save hook reads it from the process on Linux/WSL; on macOS set it for tmux too (`tmux set-environment -g KIRO_HOME ...`). `--classic`/`--legacy-ui` panes keep no lock and cannot be resolved |
| Session ID missing for Oh My Pi | The primary method is a terminal breadcrumb under `$XDG_STATE_HOME/omp` (or `~/.local/state/omp`); verify the pane tty matches the breadcrumb file. Fallback is `--resume` / `-r` / `--restore` in process args. `--session-dir` or `--profile` scoped JSONL lookup is also used when those flags are present |
| Codex/OpenCode/Pi session ID missing (python3 methods) | The save hook auto-detects `python3` in common locations. If your setup uses a non-standard path, set it in tmux: `set-environment -g PATH "/your/python3/dir:$PATH"` |
| Restore launches but assistant says "session not found" | The session ID may have expired. This is normal — start a fresh session and the next save will pick up the new ID |
| Assistants launch twice after restore | Make sure assistants are **not** listed in `@resurrect-processes` — the plugin handles all resuming via the post-restore hook |
| `just test` fails with Docker errors | Ensure Docker is running and you have network access (the image pulls npm packages) |

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
- **Kiro CLI scope**: Verified with kiro-cli 2.22.0 on Linux, in the default
  TUI (v2 engine) and with `--v3`. Both rely on session lock files that are not a
  documented interface, so a Kiro update may require changes here. The classic
  UI (`--classic`/`--legacy-ui`) keeps its conversations in a SQLite database
  with no per-process lock, so its panes are detected but not resolved and are
  not resumed. `--agent-engine v1` and macOS have not been tested.
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
- **Process inspection on macOS**: Uses `ps -eo pid= -o ppid=` instead of `pgrep -P`
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
