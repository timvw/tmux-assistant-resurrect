#!/usr/bin/env bash
# Real OpenCode 2 TUI contract for hooks/opencode2/tui.js.
#
# Usage: bash test/opencode2-tui-contract-test.sh /path/to/v2/opencode
#
# The OpenCode 2 tracker is a TUI plugin, so it only runs inside a terminal.
# This starts the real binary in a tmux pane on its own socket and checks the
# three things a hermetic test cannot: that OpenCode 2 loads the plugin, that
# the state file is keyed by the PID the save hook finds in the pane, and that
# OpenCode 2 still reports the open session through the route the plugin reads.
#
# No login, prompts, or model requests: it opens a session created over the
# local API. HOME, the XDG directories, TMPDIR and the state directory all
# point into a temporary directory, and it starts its own background server on
# a free port, so it never contacts a shared OpenCode service.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib-assert.sh
source "$REPO_DIR/test/lib-assert.sh"

OPENCODE_BIN="${1:-}"
if [ -z "$OPENCODE_BIN" ] || [ ! -x "$OPENCODE_BIN" ]; then
	echo "usage: $0 /path/to/v2/opencode" >&2
	exit 2
fi
for required in tmux jq python3 curl; do
	if ! command -v "$required" >/dev/null 2>&1; then
		skip "OpenCode 2 TUI contract" "$required not available"
		echo "$PASS passed, $FAIL failed, $SKIP skipped"
		exit 0
	fi
done

version=$("$OPENCODE_BIN" --version 2>/dev/null || true)
case "$version" in
2.* | v2.* | "opencode v2."*) ;;
*)
	echo "expected an OpenCode 2 binary, got: $version" >&2
	exit 2
	;;
esac

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opencode2-tui-contract.XXXXXX")
ROOT=$(cd "$ROOT" && pwd -P)
SOCKET="oc2-tui-contract-$$"
BIN_DIR=$(cd "$(dirname "$OPENCODE_BIN")" && pwd)

cleanup() {
	tmux -L "$SOCKET" kill-server 2>/dev/null || true
	env -i HOME="$ROOT/home" PATH="$BIN_DIR:$PATH" "$OPENCODE_BIN" service stop >/dev/null 2>&1 || true
	rm -rf "$ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT/home/.config/opencode/plugins" "$ROOT/home/project" "$ROOT/tmp"
ln -s "$REPO_DIR/hooks/opencode2" "$ROOT/home/.config/opencode/plugins/assistant-resurrect"
STATE_DIR="$ROOT/state"

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

# The pane's environment is built from scratch so the developer's own OpenCode
# directories, password and tmux pane cannot leak into the binary under test.
run_env=(env -i "HOME=$ROOT/home" "TMPDIR=$ROOT/tmp" "PATH=$BIN_DIR:$PATH" "TERM=xterm-256color"
	"TMUX_ASSISTANT_RESURRECT_DIR=$STATE_DIR" "TEST_CAPTURE_VAR=contract value")

(cd "$ROOT/home/project" && "${run_env[@]}" "$OPENCODE_BIN" service set port "$PORT" >/dev/null)

wait_for() {
	local label="$1" tries="${2:-150}"
	shift 2
	while [ "$tries" -gt 0 ]; do
		if "$@" >/dev/null 2>&1; then return 0; fi
		tries=$((tries - 1))
		sleep 0.2
	done
	fail "timed out: $label"
	return 1
}

state_file_for() { printf '%s/opencode-%s.json\n' "$STATE_DIR" "$1"; }
state_sid() { jq -r '.session_id // empty' "$(state_file_for "$1")" 2>/dev/null; }
has_sid() { [ "$(state_sid "$1")" = "$2" ]; }

tmux -L "$SOCKET" -f /dev/null new-session -d -s contract -x 140 -y 40 -c "$ROOT/home/project" \
	"${run_env[@]}" "TMUX_PANE=%contract" "$OPENCODE_BIN"

# `service set port` writes the config file before any server exists, so wait
# for the password the server adds when it starts, not for the file.
password_file="$ROOT/home/.config/opencode/service.json"
has_password() { [ -n "$(jq -r '.password // empty' "$password_file" 2>/dev/null)" ]; }
wait_for "OpenCode 2 background service starts" 150 has_password || true
password=$(jq -r '.password // empty' "$password_file" 2>/dev/null || true)

api() {
	local method="$1" route="$2" body="${3:-}"
	local directory
	directory=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$ROOT/home/project")
	if [ -n "$body" ]; then
		curl -fsS -u "opencode:$password" -X "$method" -H 'Content-Type: application/json' \
			-d "$body" "http://127.0.0.1:$PORT$route?directory=$directory"
	else
		curl -fsS -u "opencode:$password" -X "$method" "http://127.0.0.1:$PORT$route?directory=$directory"
	fi
}

wait_for "OpenCode 2 API answers" 150 api GET /api/plugin || true
inventory=$(api GET /api/plugin 2>/dev/null || echo '{}')
assert_eq "OpenCode $version reports no failed plugin" 0 \
	"$(jq '[.data[]? | select(.state.status == "failed")] | length' <<<"$inventory")"

# On the home screen no session is shown, so there is nothing to record.
sleep 2
assert_eq "no state file while the TUI shows the home screen" 0 \
	"$(find "$STATE_DIR" -name 'opencode-*.json' 2>/dev/null | wc -l | tr -d ' ')"

first=$(api POST /api/session '{"title":"contract first"}' | jq -r '.data.id // .id')
second=$(api POST /api/session '{"title":"contract second"}' | jq -r '.data.id // .id')
case "$first$second" in
*ses_*ses_*) pass "created two sessions over the local API" ;;
*) fail "created two sessions over the local API" ;;
esac

# The TUI is the pane's own process (`tmux new-session <command>`), which is
# the PID the save hook's process walk reports for the pane.
tmux -L "$SOCKET" kill-server
tmux -L "$SOCKET" -f /dev/null new-session -d -s contract -x 140 -y 40 -c "$ROOT/home/project" \
	"${run_env[@]}" "TMUX_PANE=%contract" "$OPENCODE_BIN" --session "$first"
pane_pid=$(tmux -L "$SOCKET" list-panes -t contract -F '#{pane_pid}')

if wait_for "tracker records the session the TUI opened" 150 has_sid "$pane_pid" "$first"; then
	pass "state file is keyed by the pane's opencode PID and names the open session"
	file=$(state_file_for "$pane_pid")
	assert_eq "state file records tool" opencode "$(jq -r .tool "$file")"
	assert_eq "state file records the process PID" "$pane_pid" "$(jq -r .pid "$file")"
	assert_eq "state file records the session's directory" "$ROOT/home/project" "$(jq -r .cwd "$file")"
	assert_eq "state file captures TMUX_PANE" "%contract" "$(jq -r .env.tmux_pane "$file")"
	mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
	assert_eq "state file is private" 600 "$mode"
	dir_mode=$(stat -c '%a' "$STATE_DIR" 2>/dev/null || stat -f '%Lp' "$STATE_DIR")
	assert_eq "state directory is private" 700 "$dir_mode"
	assert_eq "no temporary file is left behind" 0 \
		"$(find "$STATE_DIR" -name '*.tmp' | wc -l | tr -d ' ')"
fi

# The save hook reads this file through get_opencode_session (method 3).
resolved=$(
	TMUX_ASSISTANT_RESURRECT_DIR="$STATE_DIR" bash -c '
		source "$1/scripts/save-assistant-sessions.sh"
		get_opencode_session "$2" opencode "$3" 0
	' _ "$REPO_DIR" "$pane_pid" "$ROOT/home/project" 2>/dev/null || true
)
assert_eq "save hook resolves the pane's session from the state file" "$first" "$resolved"

# Quitting removes the file, so a later save cannot restore a closed session.
tmux -L "$SOCKET" send-keys -t contract C-c
sleep 0.5
tmux -L "$SOCKET" send-keys -t contract C-c 2>/dev/null || true
gone() { [ ! -e "$(state_file_for "$pane_pid")" ]; }
if wait_for "state file is removed when the TUI exits" 50 gone; then
	pass "state file is removed when the TUI exits"
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
