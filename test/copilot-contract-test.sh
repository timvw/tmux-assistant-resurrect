#!/usr/bin/env bash
# Contract tests for GitHub Copilot CLI — run against the REAL binary.
#
# The hermetic suite (copilot-unit-tests.sh) fabricates the on-disk artifacts it
# then looks for, so it cannot notice if Copilot changes (or never had) the
# layout we depend on. This file asserts the upstream contract itself:
#
#   1. the native process is a descendant of the npm loader, and both are
#      detected as "copilot" by detect_tool()
#   2. a live session owns $COPILOT_HOME/session-state/<uuid>/
#   3. that directory contains inuse.<native-pid>.lock, whose content is the PID
#      -- this is the PID -> session-ID mapping the save hook relies on
#   4. the lock is removed on graceful shutdown (so it is not stale-prone)
#   5. --help still advertises the session flags extract_cli_args() strips
#
# Requires the real `copilot` binary but NOT authentication: the session
# directory and lock are created before the auth check runs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v copilot >/dev/null 2>&1; then
	echo "SKIP: copilot binary not installed"
	exit 0
fi

# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib-detect.sh"

TMUX_SOCKET="copilot-contract-$$"
SANDBOX="$(mktemp -d)"
export COPILOT_HOME="$SANDBOX/copilot-home"
# Never let a save-hook-adjacent probe reach the network during CI.
export COPILOT_AUTO_UPDATE=false
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
mkdir -p "$COPILOT_HOME"

# Source the production resolver after all path overrides are set.
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1
# The sourced production hook enables errexit. This test harness records
# failures explicitly and must keep running to print the complete contract.
set +e

cleanup() {
	tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null
	rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  [pass] %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  [FAIL] %s\n' "$1"
	[ $# -gt 1 ] && printf '         %s\n' "$2"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		fail "$desc" "expected: [$expected]  actual: [$actual]"
	fi
}

# --- Launch a real Copilot session -------------------------------------------

echo "== launching real copilot under tmux =="
tmux -L "$TMUX_SOCKET" new-session -d -s contract -c "$SANDBOX" \
	"copilot --no-auto-update --allow-all --banner"

pane_pid=$(tmux -L "$TMUX_SOCKET" display-message -t contract -p '#{pane_pid}')

# The npm loader (`node .../copilot`) spawns the native binary
# (`.../copilot-<platform>-<arch>/copilot`). Walk the tree from the pane down.
# The root itself is included: when tmux runs the command without an
# intermediate shell, the pane process IS the loader.
find_copilot_pids() {
	ps -eo pid=,ppid=,args= | awk -v root="$1" '
		BEGIN { pids[root] = 1 }
		{
			if ($1 == root || $2 in pids) {
				pids[$1] = 1
				print $1 "\t" $2 "\t" substr($0, index($0, $3))
			}
		}
	'
}

native_pid=""
loader_pid=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
	# shellcheck disable=SC2034  # cppid read from structured output; only cpid and cargs used
	while IFS=$'\t' read -r cpid cppid cargs; do
		[ "$(detect_tool "$cargs")" = "copilot" ] || continue
		case "$cargs" in
		node\ * | */node\ *) loader_pid="$cpid" ;;
		*) native_pid="$cpid" ;;
		esac
	done < <(find_copilot_pids "$pane_pid")
	[ -n "$native_pid" ] && break
	sleep 0.5
done

if [ -n "$native_pid" ]; then
	pass "native copilot process found (pid $native_pid)"
else
	fail "native copilot process never appeared"
	echo "copilot contract tests: $PASS passed, $FAIL failed"
	exit 1
fi

if [ -n "$loader_pid" ]; then
	pass "npm loader also detected as copilot (pid $loader_pid)"
else
	fail "npm loader not detected as copilot" \
		"detect_tool() must match the 'node .../copilot' launcher too"
fi

# --- Contract 1: session-state/<uuid>/ ---------------------------------------

echo "== session-state layout =="
session_dir=""
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
	session_dir=$(find "$COPILOT_HOME/session-state" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
	[ -n "$session_dir" ] && break
	sleep 0.5
done

if [ -n "$session_dir" ]; then
	pass "session directory created under \$COPILOT_HOME/session-state"
else
	fail "no session directory under $COPILOT_HOME/session-state" \
		"COPILOT_HOME may no longer control the session-state root"
	echo "copilot contract tests: $PASS passed, $FAIL failed"
	exit 1
fi

session_id="${session_dir##*/}"
if echo "$session_id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
	pass "session directory name is a UUID ($session_id)"
else
	fail "session directory name is not a UUID" "got: $session_id"
fi

# --- Contract 2: inuse.<pid>.lock is the PID -> session mapping ---------------

echo "== PID to session-ID mapping =="
lock="$session_dir/inuse.$native_pid.lock"
deadline=$((SECONDS + 30))
while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$lock" ]; do sleep 0.5; done

if [ -e "$lock" ]; then
	pass "inuse.<native-pid>.lock exists in the session directory"
	assert_eq "lock file content is the native PID" "$native_pid" "$(cat "$lock" 2>/dev/null)"
else
	fail "no inuse.$native_pid.lock in $session_dir" \
		"present: $(ls -A "$session_dir" 2>/dev/null | tr '\n' ' ')"
fi

# The lock exists before any prompt is submitted, so a blank TUI IS saveable.
# If this ever regresses, the "first save after install" limitation needs an
# updated note in README.md.
if [ -e "$lock" ]; then
	pass "mapping is available on a blank TUI (no prompt submitted)"
fi

# --- Contract 3: the production resolver, and the resumability gate ----------
#
# This session has never been prompted, so it has no content and Copilot has not
# written session.db. Such a session is NOT resumable -- `--resume=<uuid>` on it
# exits with "No session, task, or name matched" -- so the resolver must decline
# it rather than hand restore a command that errors in the user's pane.
#
# The positive half (a session WITH content gains session.db and events.jsonl,
# and does resume) needs a real login: test/copilot-e2e-authenticated.sh.

echo "== resumability gate =="
if [ ! -f "$session_dir/session.db" ]; then
	pass "a never-prompted session has no session.db"
else
	fail "unexpected session.db in a session with no content" \
		"the resumability gate no longer distinguishes empty sessions"
fi

assert_eq "production resolver declines a session that cannot be resumed" \
	"" "$(get_copilot_session_from_lock "$native_pid")"

# Now stand in for "the user typed something" -- the one artifact that needs a
# paid API call. The PID, the lock and the UUID below are all real.
: >"$session_dir/session.db"
assert_eq "production resolver maps the native PID to the live session UUID" \
	"$session_id" "$(get_copilot_session_from_lock "$native_pid")"
rm -f "$session_dir/session.db"

if [ -z "$(find "$COPILOT_HOME" -maxdepth 1 -name 'session-store.db' 2>/dev/null)" ]; then
	fail "expected the shared session-store.db at the COPILOT_HOME root" \
		"present: $(ls -A "$COPILOT_HOME" 2>/dev/null | tr '\n' ' ')"
else
	pass "shared session-store.db sits at the root, not inside the session dir"
fi

# --- Contract 4: the lock is released on graceful shutdown -------------------

echo "== lock lifecycle =="
kill "$native_pid" 2>/dev/null
deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$native_pid" 2>/dev/null; do sleep 0.5; done

if [ ! -e "$lock" ]; then
	pass "lock removed when the session exits cleanly"
else
	fail "lock survived process exit" \
		"stale locks would resurrect dead sessions; needs a liveness cross-check"
fi

# --- Contract 5: --help still advertises the flags we strip ------------------

echo "== real --help flag discovery =="
help_out=$(copilot --no-auto-update --help 2>/dev/null)
for flag in --resume --session-id --prompt --interactive --continue --connect; do
	if echo "$help_out" | grep -qE "^\s+(-[a-zA-Z],\s+)?$flag([ =[]|$)"; then
		pass "--help advertises $flag"
	else
		fail "--help no longer advertises $flag" \
			"extract_cli_args() would stop stripping it; check SESSION_FLAG_PATTERN_copilot"
	fi
done

echo
echo "copilot contract tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
