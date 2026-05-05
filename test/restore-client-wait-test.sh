#!/usr/bin/env bash
# Focused restore tests for client-attachment timing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
	echo "  FAIL: $*" >&2
	exit 1
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" != "$actual" ]; then
		fail "$desc (expected '$expected', got '$actual')"
	fi
	echo "  PASS: $desc"
}

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if ! echo "$haystack" | grep -qF -- "$needle"; then
		fail "$desc (expected to contain '$needle')"
	fi
	echo "  PASS: $desc"
}

make_fake_tmux() {
	local state="$1"
	mkdir -p "$state/bin"
	cat >"$state/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -euo pipefail

state="${TMUX_FAKE_STATE:?}"
events="$state/events.log"
client_calls_file="$state/client-calls"

printf '%s\n' "$*" >>"$events"

case "${1:-}" in
has-session | list-panes | clear-history)
	exit 0
	;;
list-clients)
	calls=$(cat "$client_calls_file" 2>/dev/null || echo 0)
	calls=$((calls + 1))
	echo "$calls" >"$client_calls_file"
	if [ "$calls" -gt "${TMUX_FAKE_CLIENT_AFTER:-999}" ]; then
		echo "/dev/ttys001: ${TMUX_FAKE_SESSION:-waitsess}"
	fi
	;;
display-message)
	last=""
	for arg in "$@"; do
		last="$arg"
	done
	case "$last" in
	'#{pane_current_command}')
		echo "${TMUX_FAKE_PANE_COMMAND:-bash}"
		;;
	'#{pane_pid}')
		# Empty means the restore guard skips the process-tree check.
		;;
	esac
	;;
show-option)
	# No captured env vars in these tests.
	;;
send-keys)
	printf '%s\n' "$*" >>"$state/send-keys.log"
	;;
*)
	exit 0
	;;
esac
TMUXEOF
	chmod +x "$state/bin/tmux"
}

run_restore() {
	local state="$1" home="$2" client_after="$3" pane_command="$4"
	TMUX_FAKE_STATE="$state" \
		TMUX_FAKE_CLIENT_AFTER="$client_after" \
		TMUX_FAKE_PANE_COMMAND="$pane_command" \
		TMUX_ASSISTANT_RESURRECT_INITIAL_SLEEP_SECONDS=0 \
		TMUX_ASSISTANT_RESURRECT_CLIENT_WAIT_ATTEMPTS=5 \
		TMUX_ASSISTANT_RESURRECT_CLIENT_WAIT_INTERVAL_SECONDS=0 \
		HOME="$home" \
		PATH="$state/bin:$PATH" \
		bash "$REPO_DIR/scripts/restore-assistant-sessions.sh" >"$state/stdout.log" 2>"$state/stderr.log"
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT INT TERM

echo "=== restore client wait focused tests ==="

# Two panes in the same tmux session should wait until the first client attaches,
# then reuse that result for the second pane instead of polling again.
state="$tmp_root/wait"
home="$tmp_root/home-wait"
mkdir -p "$state" "$home/.tmux/resurrect"
make_fake_tmux "$state"
cat >"$home/.tmux/resurrect/assistant-sessions.json" <<'JSON'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "waitsess:0.0", "tool": "codex", "session_id": "ses_wait_1", "cwd": "/tmp", "pid": "99999"},
    {"pane": "waitsess:0.1", "tool": "codex", "session_id": "ses_wait_2", "cwd": "/tmp", "pid": "99998"}
  ]
}
JSON

run_restore "$state" "$home" 2 bash

client_calls=$(cat "$state/client-calls" 2>/dev/null || echo 0)
assert_eq "restore waits once per session until a client attaches" "3" "$client_calls"
assert_contains "restore still launches both panes after client attach" "$(cat "$home/.tmux/resurrect/assistant-restore.log")" "restored 2 of 2"

# Panes that fail Guard 1 should not pay the client wait at all.
state="$tmp_root/non-shell"
home="$tmp_root/home-non-shell"
mkdir -p "$state" "$home/.tmux/resurrect"
make_fake_tmux "$state"
cat >"$home/.tmux/resurrect/assistant-sessions.json" <<'JSON'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "waitsess:0.0", "tool": "codex", "session_id": "ses_skip_wait", "cwd": "/tmp", "pid": "99999"}
  ]
}
JSON

run_restore "$state" "$home" 999 sleep

client_calls=$(cat "$state/client-calls" 2>/dev/null || echo 0)
assert_eq "restore skips client wait for non-shell panes" "0" "$client_calls"
assert_contains "restore reports the guard skip" "$(cat "$home/.tmux/resurrect/assistant-restore.log")" "not a shell"
