# Testing

[← Back to README](../README.md)

## Automated tests (Docker)

The full test suite runs in Docker with real CLI binaries (no mocks):

```bash
just test
```

Fast hermetic suites cover the hardened save, restore, and installer paths:

```bash
just test-save-hardening
just test-restore
just test-cursor
just test-plugin-hardening
```

The macOS CI job also runs a real OpenCode plugin contract against pinned v1 and
v2 binaries installed in separate temporary npm prefixes. To repeat it locally:

```bash
python3 test/opencode-plugin-contract-test.py /path/to/v1/opencode /path/to/v2/opencode
```

It creates private homes and servers, verifies v1 session events, reproduces the
v2 plugin rejection, and checks that the installer removes it (including mixed
`opencode` v1 / `opencode2` v2 installations). No login or model request is needed.

`just test` builds a Docker image with tmux, jq, just, and the real
`@anthropic-ai/claude-code`, `@github/copilot`, `opencode-ai`, `@openai/codex`,
`@earendil-works/pi-coding-agent`, `@oh-my-pi/pi-coding-agent` and
`@xai-official/grok` npm packages, then runs the full test suite
covering install, save, restore, uninstall, hooks, cleanup, TPM plugin
installation, session ID extraction, POSIX quoting, process tree detection,
upgrade-path migration, and regression scenarios. Pi runs with `--offline` flag
(stays alive as TUI without API key). No API keys are needed — the
tests exercise the process detection and session management layer, not the AI
functionality.

## Performance benchmarks (Docker)

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

## Antigravity CLI (`agy`) tests

Testing has three layers:

- `bash test/agy-unit-tests.sh`: detection, selection, argument boundaries and
  the authenticated test's readiness check, including real `/proc`/`lsof` probes.
- `python3 test/agy-e2e.py`: real agy processes in two panes sharing a cwd,
  production save/restore across a tmux restart, and repeated-restore guards.
  Runs in CI with agy 1.4.3, pinned by SHA256 in `test/install-agy.sh`.
  No login or prompt is required. Conversation-selection log events are seeded
  fixtures; this verifies routing, not authenticated conversation recovery.
- `python3 test/agy-live-lifecycle.py /path/to/tmux-resurrect <UUID> 'known old message'`:
  opt-in authenticated recovery on a private tmux socket. Uses the current
  account/store and sends no prompt. It confirms workspace trust only for its
  own empty temporary directory. Success requires an actual redraw for the
  requested UUID **and** the supplied existing message visible in the pane,
  before and after restart. Launch argv alone cannot satisfy this check.
