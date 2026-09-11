#!/usr/bin/env bash
# Real tmux membership contract for PR #103. The process table is a fixture;
# pane ids, group names, membership indices and restore targets come from tmux.
# No assistant binary, credentials, or user tmux server is used.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v tmux >/dev/null 2>&1; then
	echo 'SKIP: tmux is not installed'
	exit 0
fi
REAL_TMUX=$(command -v tmux)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tar-group-contract.XXXXXX")
SOCKET="$TEST_DIR/socket"
tmux() { "$REAL_TMUX" -S "$SOCKET" -f /dev/null "$@"; }
cleanup() {
	tmux kill-server >/dev/null 2>&1 || true
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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

# Use the producer's actual format strings, so this test also covers its
# contract with awk instead of maintaining a second producer implementation.
snapshot() {
	local format pid
	while IFS= read -r format; do
		tmux list-panes -a -F "$format"
	done < <(sed -n 's/.*tmux list-panes -a -F "\([PCG]|[^"]*\)".*/\1/p' \
		"$REPO_DIR/scripts/save-assistant-sessions.sh") >"$TEST_DIR/panes"
	pid=$(tmux display-message -p -t "$tracked" '#{pane_pid}')
	printf '%s 1 claude --resume fixture-session\n' "$pid" >"$TEST_DIR/ps"
	awk -f "$REPO_DIR/scripts/lib-detect.awk" \
		-f "$REPO_DIR/scripts/save-assistant-sessions.awk" \
		"$TEST_DIR/panes" "$TEST_DIR/ps" >"$TEST_DIR/matches"
	assert_eq 'shared pane is traversed once' 1 "$(wc -l <"$TEST_DIR/matches" | tr -d ' ')"
	# Only consume address fields. Bash read collapses empty tab fields, and
	# tmux can briefly report an empty cwd while a newly started shell execs.
	IFS=$'\t' read -r label session window index < <(cut -f1,7-9 "$TEST_DIR/matches")
	assert_eq 'saved address resolves to the original pane' "$tracked" \
		"$(resolve_tmux_pane_id "$session" "$window" "$index")"
}

echo "Grouped session contract: $(tmux -V)"
tracked=$(tmux new-session -d -s main -P -F '#{pane_id}' -c "$TEST_DIR" '/bin/bash --noprofile --norc')
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command '/bin/bash --noprofile --norc'
base_id=$(tmux display-message -p -t "$tracked" '#{session_id}')
tmux new-session -d -s main-0 -t "$base_id"
tmux new-session -d -s main-1 -t "$base_id"
assert_eq 'tmux lists one pane per group membership' 3 \
	"$(tmux list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
snapshot
assert_eq 'live group name wins over clones' main:0.0 "$label"

tmux rename-session -t "$base_id" renamed
stranger=$(tmux new-session -d -s main -P -F '#{pane_id}')
assert_eq 'group name survives renaming its original session' main \
	"$(tmux display-message -p -t "$base_id" '#{session_group}')"
snapshot
assert_eq 'reused name never addresses the unrelated pane' renamed:0.0 "$label"
assert_eq 'reused name at index zero belongs to a different pane' "$stranger" \
	"$(resolve_tmux_pane_id main 0 0)"

stranger_session=$(tmux display-message -p -t "$stranger" '#{session_id}')
tmux link-window -s "$tracked" -t "$stranger_session:5"
snapshot
assert_eq 'matching membership supplies its own window index' main:5.0 "$label"

later=$(tmux new-session -d -s zzz -P -F '#{session_id}')
tmux link-window -s "$tracked" -t "$later:9"
snapshot
assert_eq 'later ungrouped membership cannot erase a group' main:5.0 "$label"

# The first group's name still exists, but no longer contains this pane.
tmux unlink-window -t "$stranger_session:5"
zulu=$(tmux new-session -d -s zulu -P -F '#{session_id}')
tmux link-window -s "$tracked" -t "$zulu:5"
tmux new-session -d -s zulu-0 -t "$zulu"
snapshot
# list-panes orders sessions by name. The still-valid group must sort after
# the renamed group's members, or this would never exercise skipping it.
assert_eq 'first observed group has no matching membership' main \
	"$(awk -F '|' -v key="$tracked" '$1 == "G" && $2 == key && $3 != "" { print $3; exit }' "$TEST_DIR/panes")"
assert_eq 'second group qualifies when first group name was renamed away' zulu:5.0 "$label"

tmux rename-session -t "$stranger_session" stranger
tmux rename-session -t "$base_id" main
snapshot
assert_eq 'earliest listed qualifying group wins' main:0.0 "$label"

# Pipe is portable even on tmux < 3.7; it must survive the G record too.
pipe_session=$(tmux new-session -d -s 'pipe|group' -P -F '#{session_id}')
tmux new-session -d -s 'pipe|group-0' -t "$pipe_session"
tracked=$(tmux display-message -p -t "$pipe_session" '#{pane_id}')
snapshot
assert_eq 'group delimiter remains literal' 'pipe|group:0.0' "$label"

echo "Grouped session contract: $PASS passed"
