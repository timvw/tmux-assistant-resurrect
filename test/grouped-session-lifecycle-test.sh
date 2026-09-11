#!/usr/bin/env bash
# Real tmux + upstream resurrect save/restart/restore, with a recording CLI
# fixture. This verifies launch routing, not an authenticated conversation.
# Pass a tmux-resurrect checkout as the first argument. No network or user
# server/config/state is touched. Each lifecycle uses a private socket.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESURRECT_PLUGIN="${1:?usage: grouped-session-lifecycle-test.sh /path/to/tmux-resurrect}"
RESURRECT_PLUGIN=$(cd "$RESURRECT_PLUGIN" && pwd)
test -f "$RESURRECT_PLUGIN/scripts/save.sh"
test -f "$RESURRECT_PLUGIN/scripts/restore.sh"
REAL_TMUX=$(command -v tmux)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tar-group-lifecycle.XXXXXX")
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
export GROUP_TEST_SOCKET="$TEST_DIR/socket" GROUP_TEST_TMUX="$REAL_TMUX"
export GROUP_TEST_LAUNCHES="$TEST_DIR/launches"
export TMUX_RESURRECT_DIR="$TEST_DIR/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$TEST_DIR/state"
export HOME="$TEST_DIR/home"
mkdir -p "$TEST_DIR/bin" "$HOME" "$TMUX_RESURRECT_DIR"
cleanup() {
	"$REAL_TMUX" -S "$GROUP_TEST_SOCKET" kill-server >/dev/null 2>&1 || true
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A tmux shim also routes calls made by upstream resurrect to our own server.
# The CLI fixture is deliberately not a wrapper around a real assistant.
cat >"$TEST_DIR/bin/tmux" <<'SH'
#!/usr/bin/env bash
exec "$GROUP_TEST_TMUX" -S "$GROUP_TEST_SOCKET" -f /dev/null "$@"
SH
cat >"$TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --help ]; then
	printf 'Usage: claude [options]\n  --resume <id> Resume session\n'
	exit 0
fi
printf '%s|%s|%s\n' "$TMUX_PANE" "$*" "$PWD" >>"$GROUP_TEST_LAUNCHES"
while :; do sleep 1; done
SH
chmod +x "$TEST_DIR/bin/tmux" "$TEST_DIR/bin/claude"
export PATH="$TEST_DIR/bin:$PATH"
# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"

PASS=0
assert_eq() {
	if [ "$2" != "$3" ]; then
		printf 'FAIL: %s\nexpected: [%s]\nactual: [%s]\n' "$1" "$2" "$3" >&2
		exit 1
	fi
	PASS=$((PASS + 1))
	printf '  PASS: %s\n' "$1"
}
wait_launch() {
	local _attempt
	for _attempt in {1..100}; do
		[ -s "$GROUP_TEST_LAUNCHES" ] && return 0
		sleep 0.1
	done
	echo 'FAIL: fixture did not launch' >&2
	exit 1
}
configure_server() {
	tmux set-option -g default-shell /bin/bash
	tmux set-option -g default-command '/bin/bash --noprofile --norc'
	tmux set-option -g @resurrect-dir "$TMUX_RESURRECT_DIR"
	tmux set-option -g @resurrect-processes false
	tmux set-option -g @resurrect-hook-post-save-all "bash $(posix_quote "$REPO_DIR/scripts/save-assistant-sessions.sh")"
	tmux set-option -g @resurrect-hook-post-restore-all "bash $(posix_quote "$REPO_DIR/scripts/restore-assistant-sessions.sh")"
}

echo "Grouped lifecycle: $(tmux -V), resurrect $(git -C "$RESURRECT_PLUGIN" rev-parse --short HEAD)"
tracked=$(tmux new-session -d -s main -c "$TEST_DIR" -P -F '#{pane_id}' '/bin/bash --noprofile --norc')
export TMUX="$GROUP_TEST_SOCKET,0,0"
configure_server
tmux new-session -d -s main-0 -t main
tmux send-keys -t "$tracked" 'claude --resume fixture-group-session' Enter
wait_launch
bash "$RESURRECT_PLUGIN/scripts/save.sh"
SAVED="$TMUX_RESURRECT_DIR/assistant-sessions.json"
assert_eq 'full save emits one assistant entry' 1 "$(jq '.sessions | length' "$SAVED")"
assert_eq 'full save prefers the base membership' main:0.0 "$(jq -r '.sessions[0].pane' "$SAVED")"
assert_eq 'upstream saves the clone as a grouped session' main-0 \
	"$(awk -F '\t' '$1 == "grouped_session" { print $2 }' "$TMUX_RESURRECT_DIR/last")"
cp "$SAVED" "$TEST_DIR/canonical.json"

# A stock restart restores both memberships before invoking the plugin hook.
tmux kill-server
: >"$GROUP_TEST_LAUNCHES"
tmux new-session -d -s bootstrap '/bin/bash --noprofile --norc'
configure_server
bash "$RESURRECT_PLUGIN/scripts/restore.sh"
wait_launch
restored=$(resolve_tmux_pane_id main 0 0)
assert_eq 'stock resurrect restores the clone sharing the base pane' "$restored" \
	"$(resolve_tmux_pane_id main-0 0 0)"
assert_eq 'stock lifecycle launches once in the shared pane' \
	"$restored|--resume fixture-group-session|$TEST_DIR" "$(cat "$GROUP_TEST_LAUNCHES")"

# Reproduce the additional condition explicitly: reap the clone at the start
# of post-restore-all, after upstream recreated it and before assistant replay.
# This is a controlled ordering, not a claim about the author's attach script.
tmux kill-server
: >"$GROUP_TEST_LAUNCHES"
tmux new-session -d -s bootstrap '/bin/bash --noprofile --norc'
configure_server
tmux set-option -g @resurrect-hook-post-restore-all \
	"tmux kill-session -t '=main-0'; bash $(posix_quote "$REPO_DIR/scripts/restore-assistant-sessions.sh")"
bash "$RESURRECT_PLUGIN/scripts/restore.sh"
wait_launch
restored=$(resolve_tmux_pane_id main 0 0)
assert_eq 'clone has been reaped' '' "$(resolve_tmux_pane_id main-0 0 0)"
assert_eq 'reaped-clone lifecycle still launches once in the base pane' \
	"$restored|--resume fixture-group-session|$TEST_DIR" "$(cat "$GROUP_TEST_LAUNCHES")"

# Same post-reaping layout, legacy last-listed clone address: restore cannot
# find a target. Kill the fixture first so assistant guards cannot mask this.
tmux respawn-pane -k -t "$restored" '/bin/bash --noprofile --norc'
: >"$GROUP_TEST_LAUNCHES"
jq '.sessions[0].session_name = "main-0" | .sessions[0].pane = "main-0:0.0"' \
	"$TEST_DIR/canonical.json" >"$SAVED"
bash "$REPO_DIR/scripts/restore-assistant-sessions.sh"
assert_eq 'clone-address control launches nothing after reaping' '' "$(cat "$GROUP_TEST_LAUNCHES")"
assert_eq 'clone-address control reports the missing pane' yes \
	"$(grep -q 'pane main-0:0.0 does not exist' "$TMUX_RESURRECT_DIR/assistant-restore.log" && echo yes)"

echo "Grouped lifecycle: $PASS passed"
