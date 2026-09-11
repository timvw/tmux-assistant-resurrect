#!/usr/bin/env bash
# Hermetic tests for restore-side validation, quoting, and per-pane failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

MOCK_BIN="$SANDBOX/bin"
RESURRECT_DIR="$SANDBOX/resurrect"
TMUX_LOG="$SANDBOX/tmux.log"
ASSISTANT_MARKER="$SANDBOX/assistant.marker"
mkdir -p "$MOCK_BIN" "$RESURRECT_DIR"

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf '  [pass] %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  [FAIL] %s\n' "$1"
}
assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		fail "$desc (expected [$expected], got [$actual])"
	fi
}
assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	case "$haystack" in
	*"$needle"*) pass "$desc" ;;
	*) fail "$desc (missing [$needle])" ;;
	esac
}
assert_not_contains() {
	local desc="$1" haystack="$2" needle="$3"
	case "$haystack" in
	*"$needle"*) fail "$desc (unexpected [$needle])" ;;
	*) pass "$desc" ;;
	esac
}

# Avoid the restore hook's deliberate startup/stagger delays.
cat >"$MOCK_BIN/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
if [ -n "${MOCK_SWAP_LOG_PATH:-}" ] && [ ! -e "${MOCK_SWAP_LOG_MARKER:-}" ]; then
	: >"$MOCK_SWAP_LOG_MARKER"
	rm -f "$MOCK_SWAP_LOG_PATH"
	ln -s "$MOCK_SWAP_LOG_TARGET" "$MOCK_SWAP_LOG_PATH"
fi
exit 0
MOCK_SLEEP

# Fabricate just the tmux surface used by restore-assistant-sessions.sh. Pane
# rows and shell names are supplied by each test through newline-separated env
# variables, keeping the assertions independent of a developer's live server.
cat >"$MOCK_BIN/tmux" <<'MOCK_TMUX'
#!/usr/bin/env bash
set -u

lookup_shell() {
	printf '%s\n' "${MOCK_SHELLS:-}" | awk -F '|' -v pane="$1" '$1 == pane { print $2; exit }'
}

# Maps a pane id to a tmux #{session_id}-shaped value ("$" + digits, the
# same $0/$1/... syntax real tmux uses -- this models the ID syntax only,
# not tmux's actual session-selection behavior for linked/grouped panes) by
# looking up which session name MOCK_PANES says that pane belongs to, then
# mapping session names to small integers in first-seen order, so panes
# sharing a session name share an id and panes in different sessions get
# different ids.
# Session names are matched on the FULL tail after the third '|' (fields 4+
# rejoined on '|'), the same "free-form field is last, take the remainder
# verbatim" convention the production -F strings use -- a session literally
# named "weird|one" must stay distinct from "weird|two", not collapse to a
# shared field-4 prefix "weird".
#
# MOCK_SESSION_ID_OVERRIDE, if set, is returned verbatim instead (used to
# simulate a malformed or failed #{session_id} lookup returning empty, or
# any other edge value).
# MOCK_SESSION_ID_OVERRIDE_PANE, if set, scopes that override to one pane id
# so a fixture can mix an unresolvable pane with an ordinary, correctly
# resolved one in the same run.
lookup_session_id() {
	local pane="$1" sess
	if [ -n "${MOCK_SESSION_ID_OVERRIDE+x}" ] &&
		{ [ -z "${MOCK_SESSION_ID_OVERRIDE_PANE:-}" ] || [ "${MOCK_SESSION_ID_OVERRIDE_PANE}" = "$pane" ]; }; then
		printf '%s\n' "$MOCK_SESSION_ID_OVERRIDE"
		return
	fi
	sess=$(printf '%s\n' "${MOCK_PANES:-}" | awk -F '|' -v pane="$pane" '
		$1 == pane {
			rest = $4
			for (i = 5; i <= NF; i++) rest = rest "|" $i
			print rest
			exit
		}')
	[ -n "$sess" ] || { printf '\n'; return; }
	printf '%s\n' "${MOCK_PANES:-}" | awk -F '|' -v want="$sess" '
		{
			rest = $4
			for (i = 5; i <= NF; i++) rest = rest "|" $i
			if (!(rest in seen)) { seen[rest] = n++ }
		}
		{
			rest = $4
			for (i = 5; i <= NF; i++) rest = rest "|" $i
		}
		rest == want { print "$" seen[want]; exit }
	'
}

case "${1:-}" in
list-panes)
	printf '%s\n' "${MOCK_PANES:-}"
	;;
list-clients)
	if [ -n "${MOCK_REMOVE_CWD_ON_WAIT:-}" ] && [ -d "$MOCK_REMOVE_CWD_ON_WAIT" ]; then
		rmdir "$MOCK_REMOVE_CWD_ON_WAIT"
	fi
	# Attribute calls by target (server-wide "" vs -t <target>) so tests can
	# assert which pane/session actually polled, and how many times, without
	# actually waiting out the 5s cap (sleep is mocked to a no-op).
	target="${3:-server}"
	if [ -n "${MOCK_LIST_CLIENTS_LOG:-}" ]; then
		printf '%s\n' "$target" >>"$MOCK_LIST_CLIENTS_LOG"
	fi
	# Reproduces the exact race the wait_invoked=1, zero-sleep case must still
	# catch: a client found on this call's very first check still leaves a
	# window in which the pane can change, because answering the check is
	# itself real elapsed time. Marks the flip pane changed, then answers
	# this call with a client attached immediately.
	if [ -n "${MOCK_FLIP_ON_LIST_CLIENTS_PANE:-}" ] && [ "$target" = "$MOCK_FLIP_ON_LIST_CLIENTS_PANE" ]; then
		: >"${MOCK_FLIP_ON_LIST_CLIENTS_MARKER:?}"
		printf 'client\n'
		exit 0
	fi
	if [ -n "${MOCK_CLIENT_AFTER_CALLS:-}" ]; then
		# Simulates a client attaching to a session mid-poll: stays empty for
		# the first MOCK_CLIENT_AFTER_CALLS calls (any target), then reports
		# one client on every call after that. This fixture only ever uses
		# one session, so applying the attach to every target is equivalent
		# to attaching to that one session; it is not a model of a client
		# reaching multiple independent sessions at once.
		count_file="${MOCK_LIST_CLIENTS_LOG:-/dev/null}.count"
		n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
		printf '%s' "$n" >"$count_file"
		if [ "$n" -gt "$MOCK_CLIENT_AFTER_CALLS" ]; then
			printf 'client\n'
		fi
	elif [ "${MOCK_NO_CLIENT:-}" != 1 ]; then
		printf 'client\n'
	fi
	;;
display-message)
	pane="${3:-}"
	case "${5:-}" in
	'#{pane_current_command}')
		if [ -n "${MOCK_PANE_CMD_CALLS_LOG:-}" ]; then
			printf '%s\n' "$pane" >>"$MOCK_PANE_CMD_CALLS_LOG"
		fi
		# MOCK_SHELL_FLIP_PANE, if set, makes this pane report
		# MOCK_SHELL_FLIP_TO starting from its second #{pane_current_command}
		# query onward -- simulates the pane's foreground process changing
		# between guard 1's first check and the post-wait re-check.
		if [ "${MOCK_SHELL_FLIP_PANE:-}" = "$pane" ]; then
			flip_count_file="${MOCK_PANE_CMD_CALLS_LOG:-/dev/null}.flip-$pane"
			n=$(($(cat "$flip_count_file" 2>/dev/null || echo 0) + 1))
			printf '%s' "$n" >"$flip_count_file"
			if [ "$n" -gt 1 ]; then
				printf '%s\n' "${MOCK_SHELL_FLIP_TO:-vim}"
				exit 0
			fi
		fi
		# The MOCK_FLIP_ON_LIST_CLIENTS_PANE marker (see list-clients above)
		# is written during the wait, inside that first list-clients call's
		# own handler, before this query ever runs -- so any
		# #{pane_current_command} query for that pane sees the changed value
		# once the marker exists. Guard 1's original query already ran
		# before the wait started, so only the post-wait re-check observes it.
		if [ -n "${MOCK_FLIP_ON_LIST_CLIENTS_PANE:-}" ] && [ "$pane" = "$MOCK_FLIP_ON_LIST_CLIENTS_PANE" ] &&
			[ -e "${MOCK_FLIP_ON_LIST_CLIENTS_MARKER:-/nonexistent}" ]; then
			printf '%s\n' "${MOCK_FLIP_ON_LIST_CLIENTS_TO:-vim}"
			exit 0
		fi
		shell_name=$(lookup_shell "$pane")
		printf '%s\n' "${shell_name:-bash}"
		;;
	'#{pane_pid}')
		[ -z "${MOCK_PANE_PID_CALLS_LOG:-}" ] || printf '%s\n' "$pane" >>"$MOCK_PANE_PID_CALLS_LOG"
		if [ "${MOCK_PANE_PID_PANE:-}" = "$pane" ]; then
			printf '%s\n' "${MOCK_PANE_PID:-999999}"
		else
			# A pid distinct from MOCK_PANE_PID/MOCK_PS_FLIP_SNAPSHOT's tree, so
			# a fixture that scopes an assistant-appearing snapshot to one pane
			# (MOCK_PANE_PID_PANE) doesn't also make every OTHER pane in the same
			# run walk that same fake tree and find the same assistant.
			printf '999999\n'
		fi
		;;
	'#{session_id}') lookup_session_id "$pane" ;;
	esac
	;;
show-option)
	case "${3:-}" in
	@assistant-resurrect-capture-env) printf '%s\n' "${MOCK_CAPTURE_ENV:-}" ;;
	@assistant-resurrect-drop-flags) printf '%s\n' "${MOCK_DROP_FLAGS:-}" ;;
	@assistant-resurrect-drop-env) printf '%s\n' "${MOCK_DROP_ENV:-}" ;;
	@assistant-resurrect-claude-drop-flags) printf '%s\n' "${MOCK_CLAUDE_DROP_FLAGS:-}" ;;
	@assistant-resurrect-claude-drop-env) printf '%s\n' "${MOCK_CLAUDE_DROP_ENV:-}" ;;
	@assistant-resurrect-relaunch) printf '%s\n' "${MOCK_RELAUNCH_ENABLED:-on}" ;;
	@assistant-resurrect-relaunch-allow-file) printf '%s\n' "${MOCK_VOUCHER:-}" ;;
	esac
	;;
clear-history)
	pane="${3:-}"
	if [ "${MOCK_FAIL_CLEAR_PANE:-}" = "$pane" ]; then exit 1; fi
	printf 'clear-history|%s\n' "$pane" >>"$MOCK_TMUX_LOG"
	;;
send-keys)
	pane="${3:-}"
	command_text="${4:-}"
	printf 'send-keys|%s|%s\n' "$pane" "$command_text" >>"$MOCK_TMUX_LOG"
	if [ "$command_text" != "clear" ] && [ -n "${MOCK_EXEC_SHELL:-}" ]; then
		case "${MOCK_EXEC_SHELL##*/}" in
		fish) "$MOCK_EXEC_SHELL" --no-config -c "$command_text" ;;
		*) "$MOCK_EXEC_SHELL" -fc "$command_text" ;;
		esac
	fi
	;;
*) exit 1 ;;
esac
MOCK_TMUX

cat >"$MOCK_BIN/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
{
	printf 'cwd=%s\n' "$PWD"
	printf 'SAFE=%s\n' "${SAFE:-}"
	printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL-UNSET}"
	printf 'REPLAY_DROP_TEST=%s\n' "${REPLAY_DROP_TEST-UNSET}"
	for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} >"$MOCK_ASSISTANT_MARKER"
MOCK_CLAUDE

# pane_has_assistant() takes an explicit process snapshot as its second
# argument in the other suites' unit tests, but restore-assistant-sessions.sh
# calls it with only a pid, so it falls back to a live `ps -eo
# pid=,ppid=,args=` snapshot. Mock that fallback here: MOCK_PS_SNAPSHOT, if
# set, is echoed verbatim (one "pid ppid args" row per line, matching what
# pane_has_assistant's own tree walk expects); otherwise this reports no
# processes at all, which is a safe default for every test that never sets
# it (pane_has_assistant then finds nothing, guard 2 passes as before).
# MOCK_PS_FLIP_AFTER_CALLS, if set, makes ps report MOCK_PS_FLIP_SNAPSHOT
# starting from that call number onward -- simulates an assistant process
# starting up inside the pane's tree partway through the restore (e.g.
# during the wait), the same "flips on a later query" idiom
# MOCK_SHELL_FLIP_PANE uses for #{pane_current_command}.
cat >"$MOCK_BIN/ps" <<'MOCK_PS'
#!/usr/bin/env bash
if [ -n "${MOCK_PS_FLIP_AFTER_CALLS:-}" ]; then
	count_file="${MOCK_PS_FLIP_COUNT_FILE:?}"
	n=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
	printf '%s' "$n" >"$count_file"
	if [ "$n" -ge "$MOCK_PS_FLIP_AFTER_CALLS" ]; then
		printf '%s\n' "$MOCK_PS_FLIP_SNAPSHOT"
		exit 0
	fi
fi
if [ -n "${MOCK_PS_SNAPSHOT+x}" ]; then
	printf '%s\n' "$MOCK_PS_SNAPSHOT"
fi
MOCK_PS

chmod +x "$MOCK_BIN/sleep" "$MOCK_BIN/tmux" "$MOCK_BIN/claude" "$MOCK_BIN/ps"

export PATH="$MOCK_BIN:$PATH"
export TMUX_RESURRECT_DIR="$RESURRECT_DIR"
export MOCK_TMUX_LOG="$TMUX_LOG"
export MOCK_ASSISTANT_MARKER="$ASSISTANT_MARKER"

run_restore() {
	: >"$TMUX_LOG"
	rm -f "$ASSISTANT_MARKER"
	RESTORE_OUTPUT=""
	RESTORE_STATUS=0
	RESTORE_OUTPUT=$("${TEST_BASH:-bash}" "$REPO_DIR/scripts/restore-assistant-sessions.sh" 2>&1) || RESTORE_STATUS=$?
}

file_mode() {
	case "$(uname -s)" in
	Darwin) stat -f '%Lp' "$1" ;;
	MINGW* | MSYS* | CYGWIN*) printf '600\n' ;;
	*) stat -c '%a' "$1" ;;
	esac
}

echo "== client wait runs once per session, not once per pane =="
client_wait_log="$SANDBOX/list-clients.log"
export MOCK_LIST_CLIENTS_LOG="$client_wait_log"
export MOCK_NO_CLIENT=1
export MOCK_EXEC_SHELL=''
export MOCK_FAIL_CLEAR_PANE=''
export MOCK_CAPTURE_ENV=''
# 5 panes across 2 sessions (3 + 2). lookup_session_id in the mock maps pane
# ids to realistic "$N" session ids from MOCK_PANES' session-name column, so
# wait-a's three panes share one id and wait-b's two panes share another.
# Each fully-timed-out wait starts one list-clients poll sequence; count wait
# STARTS per session (a fresh, otherwise-empty target appearing in the log)
# rather than the raw call count, which is coupled to the 50-attempts/100ms
# constants and would break if those ever change without the policy changing.
export MOCK_PANES='%20|0|0|wait-a
%21|0|1|wait-a
%22|0|2|wait-a
%23|0|0|wait-b
%24|0|1|wait-b'
export MOCK_SHELLS=''
jq -n '{sessions:[
  {pane:"wait-a:0.0",session_name:"wait-a",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-a0",cwd:""},
  {pane:"wait-a:0.1",session_name:"wait-a",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-a1",cwd:""},
  {pane:"wait-a:0.2",session_name:"wait-a",window_index:"0",pane_index:"2",tool:"claude",session_id:"sid-a2",cwd:""},
  {pane:"wait-b:0.0",session_name:"wait-b",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-b0",cwd:""},
  {pane:"wait-b:0.1",session_name:"wait-b",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-b1",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$client_wait_log"
run_restore
# A wait for any of these panes is logged under its pane id (this call
# passes a pane id); each poll sequence for an unseen target is a genuine
# new wait, so distinct targets polled == number of waits run.
distinct_targets_polled=$(sort -u "$client_wait_log" | grep -c '^%')
assert_eq "restore succeeds even when no client ever attaches" "0" "$RESTORE_STATUS"
assert_eq "all 5 panes across 2 sessions are still replayed" "5" "$(grep -c '^send-keys|%2[0-4]|command claude' "$TMUX_LOG")"
assert_eq "only one pane per session actually polls list-clients" "2" "$distinct_targets_polled"
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_eq "per-session no-client warning is logged exactly once per distinct session" "2" \
	"$(grep -c "no client attached to session 'wait-" <<<"$restore_log")"
unset MOCK_NO_CLIENT

echo "== a pane skipped by an eligibility guard does not consume the session's wait budget =="
: >"$client_wait_log"
export MOCK_NO_CLIENT=1
export MOCK_PANES='%30|0|0|budget-sess
%31|0|1|budget-sess'
# %30 is "vim" (fails guard 1, skipped before it can reach the wait at all);
# %31 is a normal shell and must still get its own full wait, not inherit a
# non-answer from the pane that never asked.
export MOCK_SHELLS='%30|vim
%31|bash'
jq -n '{sessions:[
  {pane:"budget-sess:0.0",session_name:"budget-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-skip",cwd:""},
  {pane:"budget-sess:0.1",session_name:"budget-sess",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-eligible",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the ineligible pane is skipped by guard 1, before any wait" "$restore_log" "pane budget-sess:0.0 is running 'vim' (not a shell), skipping"
assert_contains "the eligible pane in the same session still gets its wait" "$restore_log" "no client attached to session 'budget-sess' after 5s"
assert_eq "only the eligible pane polled list-clients" "1" "$(sort -u "$client_wait_log" | grep -c '^%')"
assert_contains "the eligible pane is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%31|command claude --resume 'sid-eligible'"
export MOCK_SHELLS=''
unset MOCK_NO_CLIENT

echo "== other eligibility failures also leave the session wait to the next pane =="
for rejection in assistant missing-cwd unvouched; do
	: >"$client_wait_log"
	export MOCK_NO_CLIENT=1
	export MOCK_PANE_PID_PANE='%30' MOCK_PANE_PID='42000'
	export MOCK_PS_SNAPSHOT=''
	first_cwd=''
	if [ "$rejection" = assistant ]; then
		export MOCK_PS_SNAPSHOT='42001 42000 claude --resume existing
42000 1 bash'
	elif [ "$rejection" = missing-cwd ]; then
		first_cwd="$SANDBOX/does-not-exist"
	fi
	export MOCK_VOUCHER="$SANDBOX/budget-voucher"
	printf '%s\n' 'claude agents' >"$MOCK_VOUCHER"
	expected_replay="command claude --resume 'sid-eligible'"
	if [ "$rejection" = unvouched ]; then
		expected_replay="command claude 'agents'"
	fi
	jq -n --arg cwd "$first_cwd" --arg rejection "$rejection" '{sessions:[
      {pane:"budget-sess:0.1",tool:"claude",session_id:"sid-eligible",cwd:""}
    ], relaunch:[]} |
    if $rejection == "unvouched" then
      .sessions = [] | .relaunch = [
        {pane:"budget-sess:0.0",tool:"claude",cmd:"claude agents --name unvouched",cwd:""},
        {pane:"budget-sess:0.1",tool:"claude",cmd:"claude agents",cwd:""}
      ]
    else
      .sessions = [{pane:"budget-sess:0.0",tool:"claude",session_id:"sid-skip",cwd:$cwd}] + .sessions
    end' >"$RESURRECT_DIR/assistant-sessions.json"
	run_restore
	assert_eq "$rejection: restore succeeds" "0" "$RESTORE_STATUS"
	assert_not_contains "$rejection: rejected pane never polls" "$(cat "$client_wait_log")" '%30'
	assert_contains "$rejection: eligible pane still polls" "$(cat "$client_wait_log")" '%31'
	assert_not_contains "$rejection: rejected pane stays untouched" "$(cat "$TMUX_LOG")" 'send-keys|%30|'
	assert_contains "$rejection: eligible pane replays" "$(cat "$TMUX_LOG")" "$expected_replay"
done
unset MOCK_NO_CLIENT MOCK_PANE_PID_PANE MOCK_PANE_PID MOCK_PS_SNAPSHOT MOCK_VOUCHER

echo "== a saved directory removed during the wait leaves the pane untouched =="
export MOCK_REMOVE_CWD_ON_WAIT="$SANDBOX/removed-during-wait"
mkdir -p "$MOCK_REMOVE_CWD_ON_WAIT"
export MOCK_PANES='%30|0|0|budget-sess
%31|0|1|budget-sess'
: >"$client_wait_log"
jq -n --arg cwd "$MOCK_REMOVE_CWD_ON_WAIT" '{sessions:[
  {pane:"budget-sess:0.0",tool:"claude",session_id:"sid-removed",cwd:$cwd},
  {pane:"budget-sess:0.1",tool:"claude",session_id:"sid-eligible",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_eq "cwd disappears: restore succeeds" "0" "$RESTORE_STATUS"
assert_not_contains "cwd disappears: no clear or resume reaches the pane" "$(cat "$TMUX_LOG")" 'send-keys|%30|'
assert_contains "cwd disappears: next pane still replays" "$(cat "$TMUX_LOG")" "send-keys|%31|command claude --resume 'sid-eligible'"
assert_not_contains "cwd disappears: consumed wait is not retried for the next pane" "$(cat "$client_wait_log")" '%31'
unset MOCK_REMOVE_CWD_ON_WAIT

echo "== an unresolvable session id disables the cache instead of falling back to a name =="
: >"$client_wait_log"
export MOCK_NO_CLIENT=1
export MOCK_SESSION_ID_OVERRIDE=''
# Defensive case: the #{session_id} lookup returns empty (a malformed or
# failed answer -- this asserts our handling of that response, not a claim
# about when real tmux produces it). If that empty result fell back to the
# session name for the cache key, a session literally named '$1' would
# silently reuse -- or poison -- an unrelated real session whose id happens
# to be $1. Assert the opposite: with no valid id, the pane still gets its
# own ordinary wait rather than being folded into any cache entry, and a
# same-named-as-a-real-id session does not short-circuit.
export MOCK_PANES='%40|0|0|$1'
jq -n '{sessions:[{pane:"$1:0.0",session_name:"$1",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-dollar1",cwd:""}]}' \
	>"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "a pane with no resolvable session id still waits (fails open to the ordinary wait, not the cache)" \
	"$restore_log" "no client attached to session '\$1' after 5s"
assert_contains "the pane is still replayed despite the unresolvable id" "$(cat "$TMUX_LOG")" "send-keys|%40|command claude --resume 'sid-dollar1'"
unset MOCK_SESSION_ID_OVERRIDE

echo "== unresolvable identity on one otherwise-eligible pane does not poison a later session whose real id equals its name =="
: >"$client_wait_log"
export MOCK_SESSION_ID_OVERRIDE=''
export MOCK_SESSION_ID_OVERRIDE_PANE='%43'
# %43 is an otherwise eligible pane whose #{session_id} lookup returns empty
# (a malformed/failed answer, scoped to that one pane via
# MOCK_SESSION_ID_OVERRIDE_PANE) and is saved with the session name '$1'.
# %44 is an ordinary, correctly resolving pane in a DIFFERENT real session
# that lookup_session_id happens to map to the id '$1' (it is the second
# distinct session name seen by the mock in this run, so it gets '$1' in
# first-seen order). If the unresolvable pane's name had leaked into
# waited_sessions as a fallback key, %44's wait would incorrectly cache-hit
# against it. It must not: %44 gets its own
# full wait.
export MOCK_PANES='%43|0|0|$1
%44|0|0|second-real-session'
jq -n --arg dollar1 '$1' '{sessions:[
  {pane:($dollar1+":0.0"),session_name:$dollar1,window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-unresolved",cwd:""},
  {pane:"second-real-session:0.0",session_name:"second-real-session",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-second-real",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the unresolvable pane still gets its own uncached wait" "$restore_log" "no client attached to session '\$1' after 5s"
assert_contains "the later session with a colliding real id ('\$1') still gets its own wait, not a poisoned cache hit" \
	"$restore_log" "no client attached to session 'second-real-session' after 5s"
assert_eq "both panes still poll list-clients independently (no cache reuse across the collision)" "2" \
	"$(sort -u "$client_wait_log" | grep -c '^%')"
assert_contains "the unresolvable pane is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%43|command claude --resume 'sid-unresolved'"
assert_contains "the colliding-id session's pane is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%44|command claude --resume 'sid-second-real'"
unset MOCK_SESSION_ID_OVERRIDE MOCK_SESSION_ID_OVERRIDE_PANE MOCK_NO_CLIENT

echo "== a name containing '|' does not corrupt the session cache =="
: >"$client_wait_log"
export MOCK_NO_CLIENT=1
# lookup_session_id derives ids from MOCK_PANES' real session-name column
# (not the sidecar's), so a '|' here exercises the same delimited-string
# scan waited_sessions and claimed_panes both use, without relying on the
# fallback path removed above -- the id itself is what must stay '|'-free.
export MOCK_PANES='%41|0|0|weird|name
%42|0|1|weird|name'
jq -n '{sessions:[
  {pane:"weird|name:0.0",session_name:"weird|name",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-weird0",cwd:""},
  {pane:"weird|name:0.1",session_name:"weird|name",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-weird1",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
assert_eq "both panes of a '|'-named session are replayed" "2" "$(grep -c '^send-keys|%4[12]|command claude' "$TMUX_LOG")"
assert_eq "the two panes still share one wait (same resolved session id)" "1" "$(sort -u "$client_wait_log" | grep -c '^%')"
unset MOCK_NO_CLIENT MOCK_LIST_CLIENTS_LOG

echo "== two DIFFERENT '|'-containing session names stay distinct, not collapsed onto a shared prefix =="
: >"$client_wait_log"
export MOCK_LIST_CLIENTS_LOG="$client_wait_log"
export MOCK_NO_CLIENT=1
# lookup_session_id must key on the full tail after the third '|' (fields 4+
# rejoined), not just field 4 -- otherwise "weird|one" and "weird|two" would
# both map to field 4 "weird" and incorrectly share one cached wait.
export MOCK_PANES='%45|0|0|weird|one
%46|0|0|weird|two'
jq -n '{sessions:[
  {pane:"weird|one:0.0",session_name:"weird|one",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-weird-one",cwd:""},
  {pane:"weird|two:0.0",session_name:"weird|two",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-weird-two",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "weird|one gets its own wait" "$restore_log" "no client attached to session 'weird|one' after 5s"
assert_contains "weird|two gets its own separate wait, not weird|one's cached result" "$restore_log" "no client attached to session 'weird|two' after 5s"
assert_eq "both distinctly-named sessions poll list-clients independently" "2" "$(sort -u "$client_wait_log" | grep -c '^%')"
unset MOCK_NO_CLIENT MOCK_LIST_CLIENTS_LOG

echo "== a client attaching partway through the FIRST pane's wait is cached for the second pane, without a second poll =="
# This documents the chosen policy rather than claiming it is invisible: the
# wait is a single best-effort five-second budget per resolved session, spent
# by whichever eligible pane asks first. MOCK_CLIENT_AFTER_CALLS=30 means the
# very first wait's poll sequence sees the client attach partway through its
# own 50 attempts (at call 31, well under the 50-attempt cap) -- pane 1's
# wait succeeds without timing out. Pane 2 in the same session then skips
# the wait entirely (cache hit): it does not re-poll to confirm the client
# is still there, and it is not itself put in a position to time out. (The
# separate, already-timed-out-session case is covered below by "a pane that
# invokes the wait (it times out) is re-checked...".)
attach_log="$SANDBOX/attach-timing.log"
: >"$attach_log"
export MOCK_LIST_CLIENTS_LOG="$attach_log"
export MOCK_CLIENT_AFTER_CALLS=30
export MOCK_PANES='%50|0|0|late-attach
%51|0|1|late-attach'
jq -n '{sessions:[
  {pane:"late-attach:0.0",session_name:"late-attach",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-late0",cwd:""},
  {pane:"late-attach:0.1",session_name:"late-attach",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-late1",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
poll_calls=$(wc -l <"$attach_log" | tr -d ' ')
assert_eq "restore succeeds when a client attaches mid-poll" "0" "$RESTORE_STATUS"
assert_not_contains "the session's one wait succeeds once the client attaches (no timeout logged)" "$restore_log" "no client attached to session"
assert_eq "both panes are still replayed" "2" "$(grep -c '^send-keys|%5[01]|command claude' "$TMUX_LOG")"
if [ "$poll_calls" -gt 30 ] && [ "$poll_calls" -lt 50 ]; then
	pass "pane 1 actually polled past the attach point ($poll_calls calls, between 30 and 50) -- the wait ran, it did not just cache-hit immediately"
else
	fail "pane 1's poll count ($poll_calls) is outside the expected mid-wait attach window (30, 50)"
fi
assert_eq "pane 2 in the same session made no list-clients calls of its own (cache hit, no second roll)" "0" \
	"$(grep -vc '^%50$' "$attach_log")"
unset MOCK_CLIENT_AFTER_CALLS MOCK_LIST_CLIENTS_LOG

echo "== no polling sleep when a client is already attached, and the cache is reused across panes =="
reuse_log="$SANDBOX/reuse.log"
cmd_calls_log="$SANDBOX/pane-cmd-calls.log"
: >"$reuse_log"
: >"$cmd_calls_log"
export MOCK_LIST_CLIENTS_LOG="$reuse_log"
export MOCK_PANE_CMD_CALLS_LOG="$cmd_calls_log"
export MOCK_PANES='%25|0|0|wait-fast
%26|0|1|wait-fast'
jq -n '{sessions:[
  {pane:"wait-fast:0.0",session_name:"wait-fast",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-fast",cwd:""},
  {pane:"wait-fast:0.1",session_name:"wait-fast",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-fast-2",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_not_contains "no wait warning is logged when a client is already attached" "$restore_log" "no client attached"
assert_contains "the first pane is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%25|command claude --resume 'sid-fast'"
assert_contains "the second pane in the same session is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%26|command claude --resume 'sid-fast-2'"
assert_eq "only the first pane in the session polled list-clients; the second reused the cached result" "1" "$(sort -u "$reuse_log" | grep -c '^%')"
# The wait's own list-clients RPC sits between guard 1 and the re-check for
# whichever pane actually invokes wait_for_session_client, even when a
# client is already attached and the RPC returns on its very first call --
# that RPC still ran, so the guards are re-checked for that one pane (query
# count 2: guard 1, then the re-check). A cache hit adds no wait-related RPC
# or sleep after guard 1 for its own pane, so it alone skips the re-check
# (query count 1). The additional post-wait re-check runs once per resolved
# session, not once per pane.
assert_eq "total #{pane_current_command} queries: one pane pays for the (instant) wait, the other is a pure cache hit" "3" \
	"$(wc -l <"$cmd_calls_log" | tr -d ' ')"
assert_eq "pane %25 (first in session, invokes the wait) is queried twice: guard 1, then the re-check" "2" \
	"$(grep -c '^%25$' "$cmd_calls_log")"
assert_eq "pane %26 (cache hit, no wait RPC of its own) is queried only once" "1" \
	"$(grep -c '^%26$' "$cmd_calls_log")"
unset MOCK_LIST_CLIENTS_LOG MOCK_PANE_CMD_CALLS_LOG

echo "== a pane that invokes the wait (it times out) is re-checked; the same session's cache-hit pane is not =="
cmd_calls_log="$SANDBOX/pane-cmd-calls-2.log"
: >"$cmd_calls_log"
export MOCK_PANE_CMD_CALLS_LOG="$cmd_calls_log"
export MOCK_NO_CLIENT=1
export MOCK_PANES='%60|0|0|blocked-sess
%61|0|1|blocked-sess'
jq -n '{sessions:[
  {pane:"blocked-sess:0.0",session_name:"blocked-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-b0",cwd:""},
  {pane:"blocked-sess:0.1",session_name:"blocked-sess",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-b1",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the session's one wait times out (never a client)" "$restore_log" "no client attached to session 'blocked-sess' after 5s"
assert_eq "both panes are still replayed" "2" "$(grep -c '^send-keys|%6[01]|command claude' "$TMUX_LOG")"
# %60 invokes wait_for_session_client (it consumes the session's budget and
# times out), so it is re-checked: guard 1 fires once before the wait and
# once after == 2 #{pane_current_command} queries. %61 never invokes the
# wait at all (cache hit) -- not "invoked but resolved fast" -- so it never
# reaches the re-check and keeps only its original guard-1 query == 1.
assert_eq "the pane that invoked the wait is queried twice (pre-wait guard 1, post-wait re-check)" "2" \
	"$(grep -c '^%60$' "$cmd_calls_log")"
assert_eq "the cache-hit pane in the same session is queried only once (no re-check)" "1" \
	"$(grep -c '^%61$' "$cmd_calls_log")"
unset MOCK_NO_CLIENT MOCK_PANE_CMD_CALLS_LOG

echo "== a pane that changes while its wait blocks is skipped by the post-wait re-check =="
export MOCK_NO_CLIENT=1
export MOCK_PANE_CMD_CALLS_LOG="$SANDBOX/pane-cmd-calls-flip.log"
: >"$MOCK_PANE_CMD_CALLS_LOG"
export MOCK_PANES='%70|0|0|flip-sess'
export MOCK_SHELL_FLIP_PANE='%70'
export MOCK_SHELL_FLIP_TO='vim'
jq -n '{sessions:[{pane:"flip-sess:0.0",session_name:"flip-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-flip",cwd:""}]}' \
	>"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the changed pane is caught by the post-wait re-check, not sent a command" "$restore_log" "pane flip-sess:0.0 changed while waiting for a client, skipping"
assert_not_contains "the changed pane never receives the clear command" "$(cat "$TMUX_LOG")" "send-keys|%70|clear"
assert_not_contains "the changed pane never receives the resume command" "$(cat "$TMUX_LOG")" "send-keys|%70|command claude"
unset MOCK_NO_CLIENT MOCK_SHELL_FLIP_PANE MOCK_SHELL_FLIP_TO MOCK_PANE_CMD_CALLS_LOG

echo "== an assistant that starts inside the pane's tree during the wait is caught by the post-wait guard-2 re-check =="
# #{pane_current_command} stays bash throughout (guard 1 alone would pass
# both times); only the process-tree walk in pane_has_assistant changes.
# ps's FIRST call is guard 2's pre-wait check and reports no assistant; ps's
# SECOND call is the post-wait re-check and reports a claude process now
# parented under the pane's shell pid. Two panes share the session so the
# other pane's replay proves the skip is scoped to the one pane whose tree
# changed.
export MOCK_NO_CLIENT=1
export MOCK_PANE_PID='42000'
export MOCK_PANE_PID_PANE='%90'
export MOCK_PS_FLIP_AFTER_CALLS=2
export MOCK_PS_FLIP_COUNT_FILE="$SANDBOX/ps-flip-count"
rm -f "$MOCK_PS_FLIP_COUNT_FILE"
export MOCK_PS_FLIP_SNAPSHOT=' 42001 42000 claude --resume ses_appeared
 42000 1 bash'
export MOCK_PANES='%90|0|0|assistant-appears-sess
%91|0|1|assistant-appears-sess'
jq -n '{sessions:[
  {pane:"assistant-appears-sess:0.0",session_name:"assistant-appears-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-appears",cwd:""},
  {pane:"assistant-appears-sess:0.1",session_name:"assistant-appears-sess",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-appears-2",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the pane whose tree gained an assistant is caught by the re-check, not sent a command" \
	"$restore_log" "pane assistant-appears-sess:0.0 already has a running assistant"
assert_not_contains "the clear is never sent to the pane that gained an assistant" "$(cat "$TMUX_LOG")" "send-keys|%90|clear"
assert_not_contains "the resume command is never sent to the pane that gained an assistant" "$(cat "$TMUX_LOG")" "send-keys|%90|command claude"
assert_contains "the other pane in the same session still replays" "$(cat "$TMUX_LOG")" "send-keys|%91|command claude --resume 'sid-appears-2'"
unset MOCK_NO_CLIENT MOCK_PANE_PID MOCK_PANE_PID_PANE MOCK_PS_FLIP_AFTER_CALLS MOCK_PS_FLIP_COUNT_FILE MOCK_PS_FLIP_SNAPSHOT

echo "== a foreground switch between two whitelisted shells during the wait is still caught (command was quoted for the original shell) =="
# Both shells are whitelisted, so a recheck that only rejects a non-shell
# value would let this switch through even though the command was quoted
# for bash and tcsh needs different quoting rules.
export MOCK_NO_CLIENT=1
export MOCK_PANE_CMD_CALLS_LOG="$SANDBOX/pane-cmd-calls-shellswitch.log"
: >"$MOCK_PANE_CMD_CALLS_LOG"
export MOCK_PANES='%92|0|0|shell-switch-sess
%93|0|1|shell-switch-sess'
export MOCK_SHELLS='%92|bash
%93|bash'
export MOCK_SHELL_FLIP_PANE='%92'
export MOCK_SHELL_FLIP_TO='tcsh'
jq -n '{sessions:[
  {pane:"shell-switch-sess:0.0",session_name:"shell-switch-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-switch",cwd:""},
  {pane:"shell-switch-sess:0.1",session_name:"shell-switch-sess",window_index:"0",pane_index:"1",tool:"claude",session_id:"sid-switch-2",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "the pane that switched shells is caught by the re-check, not sent a command" \
	"$restore_log" "pane shell-switch-sess:0.0 changed while waiting for a client, skipping"
assert_not_contains "the clear is never sent to the pane that switched shells" "$(cat "$TMUX_LOG")" "send-keys|%92|clear"
assert_not_contains "the bash-quoted resume command is never sent to the now-tcsh pane" "$(cat "$TMUX_LOG")" "send-keys|%92|command claude"
assert_contains "the other pane in the same session still replays" "$(cat "$TMUX_LOG")" "send-keys|%93|command claude --resume 'sid-switch-2'"
unset MOCK_NO_CLIENT MOCK_PANE_CMD_CALLS_LOG MOCK_SHELLS MOCK_SHELL_FLIP_PANE MOCK_SHELL_FLIP_TO

echo "== a pane that changes during the wait's first (and only) list-clients call is still caught, even though the wait never sleeps =="
# Zero sleeps does not mean zero elapsed time: a client found on the very
# first check still leaves a window in which the pane can change, because
# answering that check is itself real elapsed time. If the re-check were
# skipped whenever the wait resolved without sleeping, this pane would be
# sent a resume command while a different program owns its foreground.
flip_marker="$SANDBOX/flip-on-list-clients.marker"
rm -f "$flip_marker"
export MOCK_FLIP_ON_LIST_CLIENTS_PANE='%80'
export MOCK_FLIP_ON_LIST_CLIENTS_MARKER="$flip_marker"
export MOCK_FLIP_ON_LIST_CLIENTS_TO='sleep'
export MOCK_PANES='%80|0|0|zero-sleep-sess'
jq -n '{sessions:[{pane:"zero-sleep-sess:0.0",session_name:"zero-sleep-sess",window_index:"0",pane_index:"0",tool:"claude",session_id:"sid-zero-sleep",cwd:""}]}' \
	>"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_not_contains "the wait never times out (client attached on its first call)" "$restore_log" "no client attached to session"
assert_contains "the pane is still caught by the re-check despite the wait resolving on its first poll" \
	"$restore_log" "pane zero-sleep-sess:0.0 changed while waiting for a client, skipping"
assert_not_contains "the changed pane never receives the clear command, even at zero sleeps" "$(cat "$TMUX_LOG")" "send-keys|%80|clear"
assert_not_contains "the changed pane never receives the resume command, even at zero sleeps" "$(cat "$TMUX_LOG")" "send-keys|%80|command claude"
unset MOCK_FLIP_ON_LIST_CLIENTS_PANE MOCK_FLIP_ON_LIST_CLIENTS_MARKER MOCK_FLIP_ON_LIST_CLIENTS_TO

echo "== csh/tcsh-safe command reconstruction =="
csh_cwd="$SANDBOX/cwd!bang"
mkdir -p "$csh_cwd"
export MOCK_PANES='%1|0|0|csh-test'
export MOCK_SHELLS='%1|tcsh'
export MOCK_CAPTURE_ENV='SAFE'
export MOCK_FAIL_CLEAR_PANE=''
export MOCK_EXEC_SHELL=''

jq -n --arg cwd "$csh_cwd" '{sessions:[{
  pane:"csh-test:0.0", session_name:"csh-test", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-valid", cwd:$cwd,
  cli_args:"--model-provider provider!choice", model:"model!choice",
  env:{SAFE:"env!choice"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_eq "restore succeeds" "0" "$RESTORE_STATUS"
csh_tmux_log=$(cat "$TMUX_LOG")
assert_contains "csh cwd history character is escaped" "$csh_tmux_log" "cwd\\!bang' &&"
assert_contains "captured env uses the alias-safe env launcher" "$csh_tmux_log" "\\env SAFE='env\\!choice' claude"
assert_contains "model-like options do not suppress the saved model" "$csh_tmux_log" "'--model-provider' 'provider\\!choice' --model 'model\\!choice'"
assert_not_contains "csh command does not use POSIX fd redirection" "$csh_tmux_log" "2>/dev/null"

if command -v tcsh >/dev/null 2>&1; then
	export MOCK_EXEC_SHELL
	MOCK_EXEC_SHELL=$(command -v tcsh)
	run_restore
	marker=$(cat "$ASSISTANT_MARKER" 2>/dev/null || true)
	assert_contains "tcsh executes in the saved cwd" "$marker" "cwd=$csh_cwd"
	assert_contains "tcsh passes literal ! in captured env" "$marker" "SAFE=env!choice"
	assert_contains "tcsh passes literal ! in CLI args" "$marker" "arg=provider!choice"
	assert_contains "tcsh receives the separately saved model" "$marker" "arg=model!choice"

	# csh/tcsh have no `command` builtin, so the no-env path must still go
	# through `env`. This assertion used to expect the `command` form and
	# passed only on macOS, which ships /usr/bin/command as an external script;
	# on Linux that form fails with "command: Command not found."
	#
	# The backslash matters as much as the launcher: csh applies alias
	# substitution to the first word, so a bare `env` is hijacked by a user's
	# `alias env ...` in ~/.cshrc, verified against tcsh. `\env` suppresses that
	# lookup, which is the property `command` provides in POSIX shells.
	export MOCK_CAPTURE_ENV=''
	jq -n '{sessions:[{
	  pane:"csh-test:0.0", session_name:"csh-test", window_index:"0", pane_index:"0",
	  tool:"claude", session_id:"sid-no-env", cwd:"", env:{}
	}]}' >"$RESURRECT_DIR/assistant-sessions.json"
	run_restore
	marker=$(cat "$ASSISTANT_MARKER" 2>/dev/null || true)
	assert_contains "tcsh no-env resume uses the alias-safe env launcher" "$(cat "$TMUX_LOG")" \
		"send-keys|%1|\\env claude --resume 'sid-no-env'"
	assert_not_contains "tcsh never emits the absent command builtin" "$(cat "$TMUX_LOG")" \
		"command claude"
	assert_contains "tcsh executes the no-env resume command" "$marker" "arg=sid-no-env"
else
	pass "tcsh unavailable; portable command shape still covered"
fi
export MOCK_EXEC_SHELL=''
assert_eq "restore log is owner-only" "600" "$(file_mode "$RESURRECT_DIR/assistant-restore.log")"

echo "== Nushell-specific command construction =="
nu_cwd="$SANDBOX/nu cwd's"
mkdir -p "$nu_cwd"
export MOCK_PANES='%9|0|0|nu-test'
export MOCK_SHELLS='%9|nu'
export MOCK_CAPTURE_ENV='SAFE'
nu_cli_args="--permission-mode plan's"
nu_model="model's"
nu_env_value="nu-value's"
MSYS2_ARG_CONV_EXCL='*' jq -n --arg cwd "$nu_cwd" --arg cli_args "$nu_cli_args" \
	--arg model "$nu_model" --arg env_value "$nu_env_value" '{sessions:[{
  pane:"nu-test:0.0", session_name:"nu-test", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-nu", cwd:$cwd,
  cli_args:$cli_args, model:$model, env:{SAFE:$env_value}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
nu_tmux_log=$(cat "$TMUX_LOG")
expected_nu_cmd="send-keys|%9|cd r#'$nu_cwd'#; with-env { SAFE: r#'nu-value's'# } { ^claude r#'--permission-mode'# r#'plan's'# --model r#'model's'# --resume r#'sid-nu'# }"
assert_contains "Nushell restore command preserves exact ordering and values" "$nu_tmux_log" "$expected_nu_cmd"
assert_not_contains "Nushell cwd does not use unsupported &&" "$nu_tmux_log" " && "

echo "== Cursor Agent CLI command reconstruction =="
export MOCK_PANES='%14|0|0|cursor-test'
export MOCK_SHELLS='%14|bash'
export MOCK_CAPTURE_ENV=''
jq -n '{sessions:[{
  pane:"cursor-test:0.0", session_name:"cursor-test", window_index:"0", pane_index:"0",
  tool:"cursor", session_id:"750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2", cwd:"",
  cursor_binary:"agent", cli_args:"--mode plan --model auto --sandbox enabled", env:{}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_eq "Cursor restore succeeds" "0" "$RESTORE_STATUS"
assert_contains "Cursor resumes the exact session with saved invocation flags" "$(cat "$TMUX_LOG")" \
	"command agent '--mode' 'plan' '--model' 'auto' '--sandbox' 'enabled' --resume '750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2'"

echo "== malformed entries are isolated =="
export MOCK_PANES='%1|0|0|bad-env
%2|0|0|bad-id
%3|0|0|missing-cwd
%4|0|0|good'
export MOCK_SHELLS=''
export MOCK_CAPTURE_ENV=''
jq -n --arg missing "$SANDBOX/does-not-exist" '{sessions:[
  "not-an-object",
  {pane:"bad-env:0.0",tool:"claude",session_id:"sid-env",cwd:"",env:[]},
  {pane:"bad-id:0.0",tool:"codex",session_id:"--danger",cwd:""},
  {pane:"missing-cwd:0.0",tool:"claude",session_id:"sid-cwd",cwd:$missing},
  {pane:"good:0.0",tool:"claude",session_id:"sid-good",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_eq "corrupt entries do not make restore fail" "0" "$RESTORE_STATUS"
assert_contains "non-object entry is rejected" "$restore_log" "malformed sidecar entry 1"
assert_contains "bad env shape is rejected" "$restore_log" "malformed sidecar entry 2"
assert_contains "option-shaped session id is rejected" "$restore_log" "invalid or empty session id"
assert_contains "stale cwd is rejected" "$restore_log" "no longer exists"
assert_not_contains "stale cwd pane is not cleared" "$(cat "$TMUX_LOG")" "send-keys|%3|clear"
assert_contains "later valid entry is still replayed" "$(cat "$TMUX_LOG")" "send-keys|%4|command claude --resume 'sid-good'"
assert_contains "only the valid entry is counted" "$restore_log" "restored 1 of 5"

export MOCK_PANES='%6|0|0|broader-id'
jq -n '{sessions:[{
  pane:"broader-id:0.0",tool:"codex",session_id:"_base64/id+=",cwd:""
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_contains "safe non-option session ID alphabet is accepted" "$(cat "$TMUX_LOG")" \
	"command codex resume '_base64/id+='"

echo "== one disappearing pane does not abort later panes =="
export MOCK_PANES='%1|0|0|gone
%2|0|0|survives'
export MOCK_FAIL_CLEAR_PANE='%1'
jq -n '{sessions:[
  {pane:"gone:0.0",tool:"claude",session_id:"sid-gone",cwd:""},
  {pane:"survives:0.0",tool:"claude",session_id:"sid-survives",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_eq "tmux race is handled without aborting restore" "0" "$RESTORE_STATUS"
assert_contains "failed pane is reported" "$restore_log" "disappeared while clearing"
assert_contains "later pane is replayed" "$(cat "$TMUX_LOG")" "send-keys|%2|command claude --resume 'sid-survives'"
assert_contains "summary excludes the failed pane" "$restore_log" "restored 1 of 2"
export MOCK_FAIL_CLEAR_PANE=''

echo "== duplicate panes and log integrity =="
export MOCK_PANES='%5|0|0|duplicate'
jq -n '{sessions:[
  {pane:"duplicate:0.0",tool:"claude",session_id:"sid-first",cwd:""},
  {pane:"duplicate:0.0",tool:"claude",session_id:"sid-second",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
replay_count=$(grep -c '^send-keys|%5|command claude' "$TMUX_LOG" || true)
assert_eq "a pane receives at most one replay command" "1" "$replay_count"
assert_contains "duplicate pane is reported" "$restore_log" "duplicate sidecar entry"
assert_contains "duplicate pane is excluded from summary" "$restore_log" "restored 1 of 2"

evil_tool=$(printf 'claude\nFORGED-LOG-LINE')
jq -n --arg tool "$evil_tool" '{sessions:[
  {pane:"duplicate:0.0",tool:$tool,session_id:"--invalid",cwd:""}
]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
escaped_lines=$(grep -c 'claude.*FORGED-LOG-LINE' "$RESURRECT_DIR/assistant-restore.log" || true)
assert_eq "embedded newline is escaped onto one log line" "1" "$escaped_lines"
forged_lines=$(grep -c '^FORGED-LOG-LINE' "$RESURRECT_DIR/assistant-restore.log" || true)
assert_eq "standalone injected log line is rejected" "0" "$forged_lines"

echo "== invalid top-level schema and log symlink =="
missing_resurrect_dir="$SANDBOX/missing-resurrect-dir"
TMUX_RESURRECT_DIR="$missing_resurrect_dir" run_restore
assert_eq "missing resurrect directory is a non-fatal cache miss" "0" "$RESTORE_STATUS"
assert_contains "unwritable log does not hide the cache-miss message" "$RESTORE_OUTPUT" "no saved sessions found"

printf '%s\n' '{"sessions":"not-an-array"}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_eq "invalid root schema is a non-fatal cache miss" "0" "$RESTORE_STATUS"
assert_contains "invalid root schema is reported" "$RESTORE_OUTPUT" "invalid assistant sidecar"
assert_eq "invalid root schema sends no keys" "" "$(cat "$TMUX_LOG")"

symlink_dir="$SANDBOX/symlink-resurrect"
victim="$SANDBOX/victim"
mkdir -p "$symlink_dir"
printf 'do-not-touch\n' >"$victim"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	pass "symlinked-log check skipped where POSIX symlinks are unavailable"
	;;
*)
	ln -s "$victim" "$symlink_dir/assistant-restore.log"
	printf '%s\n' '{"sessions":[]}' >"$symlink_dir/assistant-sessions.json"
	TMUX_RESURRECT_DIR="$symlink_dir" run_restore
	assert_contains "symlinked log is refused" "$RESTORE_OUTPUT" "refusing symlinked restore log"
	assert_eq "symlink target remains unchanged" "do-not-touch" "$(cat "$victim")"
	;;
esac

echo "== restore log descriptor resists a post-open symlink swap =="
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	pass "post-open symlink-swap check skipped where POSIX symlinks are unavailable"
	;;
*)
	race_dir="$SANDBOX/log-race-resurrect"
	race_target="$SANDBOX/log-race-target"
	race_marker="$SANDBOX/log-race-marker"
	mkdir -p "$race_dir"
	printf 'old log\n' >"$race_dir/assistant-restore.log"
	printf 'do-not-touch\n' >"$race_target"
	printf '%s\n' '{"sessions":[{"pane":"race:0.0","tool":"claude","session_id":"sid-race","cwd":""}]}' \
		>"$race_dir/assistant-sessions.json"
	export MOCK_PANES='%8|0|0|race'
	export MOCK_SHELLS=''
	export MOCK_SWAP_LOG_PATH="$race_dir/assistant-restore.log"
	export MOCK_SWAP_LOG_TARGET="$race_target"
	export MOCK_SWAP_LOG_MARKER="$race_marker"
	TMUX_RESURRECT_DIR="$race_dir" run_restore
	assert_eq "post-open symlink swap cannot redirect restore log writes" \
		"do-not-touch" "$(cat "$race_target")"
	unset MOCK_SWAP_LOG_PATH MOCK_SWAP_LOG_TARGET MOCK_SWAP_LOG_MARKER
	;;
esac

echo "== captured env values are redacted in restore log =="
secret_cwd="$SANDBOX/secret-cwd"
mkdir -p "$secret_cwd"
export MOCK_PANES='%10|0|0|secret-env'
export MOCK_SHELLS='%10|bash'
export MOCK_CAPTURE_ENV='ANTHROPIC_API_KEY SAFE_VAR'
export MOCK_FAIL_CLEAR_PANE=''
export MOCK_EXEC_SHELL=''
jq -n --arg cwd "$secret_cwd" '{sessions:[{
  pane:"secret-env:0.0", session_name:"secret-env", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-secret", cwd:$cwd,
  env:{ANTHROPIC_API_KEY:"sk-ant-api03-VERYSECRETKEY", SAFE_VAR:"public-value"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
tmux_log=$(cat "$TMUX_LOG")
assert_eq "restore with secret env succeeds" "0" "$RESTORE_STATUS"
# The log must show variable NAMES but never their values
assert_contains "log shows ANTHROPIC_API_KEY name" "$restore_log" "ANTHROPIC_API_KEY=***"
assert_contains "log shows SAFE_VAR name" "$restore_log" "SAFE_VAR=***"
assert_not_contains "log does not contain the secret value" "$restore_log" "sk-ant-api03-VERYSECRETKEY"
assert_not_contains "log does not contain the safe value either" "$restore_log" "public-value"
# But the actual command sent to the pane MUST contain the real values
assert_contains "pane command has the real secret" "$tmux_log" "sk-ant-api03-VERYSECRETKEY"
assert_contains "pane command has the real safe value" "$tmux_log" "public-value"

# The redacted string is rendered per shell dialect. A POSIX VAR=*** inside a
# Nushell `with-env { }` block would misreport what was sent, and the log is
# read as a record of exactly that.
export MOCK_PANES='%11|0|0|secret-nu'
export MOCK_SHELLS='%11|nu'
export MOCK_CAPTURE_ENV='ANTHROPIC_API_KEY'
jq -n --arg cwd "$secret_cwd" '{sessions:[{
  pane:"secret-nu:0.0", session_name:"secret-nu", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-secret-nu", cwd:$cwd,
  env:{ANTHROPIC_API_KEY:"sk-ant-api03-VERYSECRETKEY"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
# run_restore truncates TMUX_LOG but the restore log is append-only across runs,
# so clear it first or the previous case's POSIX-form line is still matched here.
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
nu_restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
assert_contains "nu log redacts in nu record syntax" "$nu_restore_log" "with-env { ANTHROPIC_API_KEY: *** }"
assert_not_contains "nu log does not use POSIX assignment syntax" "$nu_restore_log" "ANTHROPIC_API_KEY=***"
assert_not_contains "nu log does not contain the secret value" "$nu_restore_log" "sk-ant-api03-VERYSECRETKEY"

# csh/tcsh plus a captured secret is the one combination neither the csh fix nor
# the redaction fix could regress on its own: the alias-safe launcher is chosen
# on the resume line, the redacted line is built separately, and nothing forced
# the two to agree. They were developed on separate branches, so this crossing
# only became reachable when both landed -- which is exactly the shape of defect
# that survives per-branch green CI. If the log line ever falls back to a plain
# `env`, it advertises a command csh was never sent.
export MOCK_PANES='%12|0|0|secret-csh'
export MOCK_SHELLS='%12|tcsh'
export MOCK_CAPTURE_ENV='ANTHROPIC_API_KEY'
jq -n --arg cwd "$secret_cwd" '{sessions:[{
  pane:"secret-csh:0.0", session_name:"secret-csh", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-secret-csh", cwd:$cwd,
  env:{ANTHROPIC_API_KEY:"sk-ant-api03-VERYSECRETKEY"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
csh_secret_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
csh_secret_tmux=$(cat "$TMUX_LOG")
assert_contains "csh pane receives the alias-safe launcher and the real secret" \
	"$csh_secret_tmux" "\\env ANTHROPIC_API_KEY='sk-ant-api03-VERYSECRETKEY' claude"
assert_contains "csh log redacts behind the same alias-safe launcher" \
	"$csh_secret_log" "\\env ANTHROPIC_API_KEY=*** claude"
assert_not_contains "csh log does not contain the secret value" \
	"$csh_secret_log" "sk-ant-api03-VERYSECRETKEY"
assert_not_contains "csh log never advertises the bare env launcher" \
	"$csh_secret_log" " env ANTHROPIC_API_KEY=***"

# COPILOT_HOME is a state-root path the plugin derives, not user-supplied
# credential material. Masking it breaks the main reason to read this log --
# seeing which state root a restore actually landed on -- so it must stay
# readable even while a captured secret alongside it is masked.
# A space, but deliberately no apostrophe: this assertion is about masking, and
# an apostrophe would make the expected string depend on shell_quote's escaping
# instead. Quoting of hostile paths is covered by the Nushell section above.
copilot_state_root="$SANDBOX/copilot home"
mkdir -p "$copilot_state_root"
export MOCK_PANES='%12|0|0|secret-copilot'
export MOCK_SHELLS='%12|bash'
export MOCK_CAPTURE_ENV='ANTHROPIC_API_KEY'
jq -n --arg cwd "$secret_cwd" --arg home "$copilot_state_root" '{sessions:[{
  pane:"secret-copilot:0.0", session_name:"secret-copilot", window_index:"0", pane_index:"0",
  tool:"copilot", session_id:"sid-secret-copilot", cwd:$cwd, copilot_home:$home,
  env:{ANTHROPIC_API_KEY:"sk-ant-api03-VERYSECRETKEY"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
copilot_restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
# Compare against the value the sidecar actually holds, not the shell variable.
# Git-bash on Windows rewrites POSIX-looking absolute paths when they are passed
# as arguments to a native binary, so jq stores "C:/Users/..." where this script
# said "/tmp/...". Reading it back keeps the assertion about masking rather than
# about MSYS path translation.
copilot_home_saved=$(jq -r '.sessions[0].copilot_home' "$RESURRECT_DIR/assistant-sessions.json")
assert_contains "copilot log keeps the state root readable" "$copilot_restore_log" "COPILOT_HOME='$copilot_home_saved'"
assert_not_contains "copilot state root is not masked" "$copilot_restore_log" "COPILOT_HOME=***"
assert_contains "captured secret alongside it is still masked" "$copilot_restore_log" "ANTHROPIC_API_KEY=***"
assert_not_contains "copilot log does not contain the secret value" "$copilot_restore_log" "sk-ant-api03-VERYSECRETKEY"

# Sidecars written before the save-side filter existed still hold credential
# flags and are read verbatim. Restore must not replay one into the pane or copy
# it into the log, so the save fix alone is not sufficient.
export MOCK_PANES='%13|0|0|legacy-sidecar'
export MOCK_SHELLS='%13|bash'
export MOCK_CAPTURE_ENV=''
jq -n --arg cwd "$secret_cwd" '{sessions:[{
  pane:"legacy-sidecar:0.0", session_name:"legacy-sidecar", window_index:"0", pane_index:"0",
  tool:"pi", session_id:"sid-legacy", cwd:$cwd,
  cli_args:"--api-key sk-LEGACYSECRET --model gpt-4"
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
: >"$RESURRECT_DIR/assistant-restore.log"
run_restore
legacy_restore_log=$(cat "$RESURRECT_DIR/assistant-restore.log")
legacy_tmux_log=$(cat "$TMUX_LOG")
assert_not_contains "legacy sidecar secret is not logged" "$legacy_restore_log" "sk-LEGACYSECRET"
assert_not_contains "legacy sidecar secret is not sent to the pane" "$legacy_tmux_log" "sk-LEGACYSECRET"
assert_contains "legacy sidecar strip is reported" "$legacy_restore_log" "stripped credential flag(s) from saved pi cli_args: --api-key"
assert_contains "surrounding args from the legacy sidecar survive" "$legacy_tmux_log" "'--model' 'gpt-4'"

echo "== independent argument and environment opt-outs =="
export MOCK_PANES='%14|0|0|opt-out'
export MOCK_SHELLS='%14|bash'
export MOCK_EXEC_SHELL=bash
export MOCK_DROP_FLAGS=--model
export MOCK_CLAUDE_DROP_FLAGS=--settings
export MOCK_DROP_ENV='REPLAY_DROP_TEST BAD-NAME'
export MOCK_CLAUDE_DROP_ENV=ANTHROPIC_MODEL
export MOCK_CAPTURE_ENV='ANTHROPIC_MODEL REPLAY_DROP_TEST SAFE'
export ANTHROPIC_MODEL=opus
export REPLAY_DROP_TEST=inherited
jq -n --arg cwd "$SANDBOX" '{sessions:[{
  pane:"opt-out:0.0",session_name:"opt-out",window_index:"0",pane_index:"0",
  tool:"claude",session_id:"sid-opt-out",cwd:$cwd,
  cli_args:"--model opus --model=sonnet --settings old-pane.json --verbose",model:"opus",
  env:{ANTHROPIC_MODEL:"haiku",REPLAY_DROP_TEST:"captured",SAFE:"retained"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
for test_shell in bash zsh fish tcsh nu; do
	export MOCK_SHELLS="%14|$test_shell"
	export MOCK_EXEC_SHELL=''
	if command -v "$test_shell" >/dev/null 2>&1; then
		MOCK_EXEC_SHELL=$(command -v "$test_shell")
	fi
	run_restore
	assert_eq "$test_shell restore succeeds with both opt-outs" 0 "$RESTORE_STATUS"
	opt_out_cmd=$(cat "$TMUX_LOG")
	assert_not_contains "$test_shell does not replay model metadata or flags" "$opt_out_cmd" --model
	assert_not_contains "$test_shell does not replay the old settings" "$opt_out_cmd" old-pane.json
	case "$test_shell" in
	nu)
		assert_contains "$test_shell removes the inherited model variable" "$opt_out_cmd" "-u r#'ANTHROPIC_MODEL'#"
		assert_contains "$test_shell retains the session selector" "$opt_out_cmd" "--resume r#'sid-opt-out'#"
		;;
	*)
		assert_contains "$test_shell removes the inherited model variable" "$opt_out_cmd" "-u 'ANTHROPIC_MODEL'"
		assert_contains "$test_shell retains the session selector" "$opt_out_cmd" "--resume 'sid-opt-out'"
		;;
	esac
	assert_contains "$test_shell retains unrelated flags" "$opt_out_cmd" "'--verbose'"
	if [ -n "$MOCK_EXEC_SHELL" ]; then
		opt_out_result=$(cat "$ASSISTANT_MARKER")
		assert_contains "$test_shell child does not inherit a model override" "$opt_out_result" 'ANTHROPIC_MODEL=UNSET'
		assert_contains "$test_shell drop wins over capture and inheritance" "$opt_out_result" 'REPLAY_DROP_TEST=UNSET'
		assert_contains "$test_shell unrelated captured env survives" "$opt_out_result" 'SAFE=retained'
	else
		printf '  [skip] %s execution (binary unavailable); command checked\n' "$test_shell"
	fi
done
assert_eq 'removing child environment does not mutate the parent' opus "$ANTHROPIC_MODEL"
export MOCK_SHELLS='%14|bash'
export MOCK_EXEC_SHELL=bash
export MOCK_DROP_ENV='' MOCK_CLAUDE_DROP_ENV=''
run_restore
assert_contains 'argument opt-out alone still permits captured model env' "$(cat "$ASSISTANT_MARKER")" 'ANTHROPIC_MODEL=haiku'
export MOCK_CAPTURE_ENV=''
run_restore
assert_contains 'argument opt-out alone still permits inherited model env' "$(cat "$ASSISTANT_MARKER")" 'ANTHROPIC_MODEL=opus'
export MOCK_DROP_FLAGS='' MOCK_CLAUDE_DROP_FLAGS=''
export MOCK_DROP_ENV=ANTHROPIC_MODEL
run_restore
assert_contains 'environment opt-out alone retains the CLI model' "$(cat "$ASSISTANT_MARKER")" 'arg=--model'
assert_contains 'environment opt-out alone removes the inherited model' "$(cat "$ASSISTANT_MARKER")" 'ANTHROPIC_MODEL=UNSET'

# A plugin-derived state root identifies a specific Copilot conversation.
# Failing closed honors the exclusion without opening a different state root.
export MOCK_EXEC_SHELL=''
export MOCK_DROP_ENV=COPILOT_HOME
jq --arg cwd "$SANDBOX" '.sessions[0] |= (.tool="copilot" | .copilot_home=$cwd)' \
	"$RESURRECT_DIR/assistant-sessions.json" >"$SANDBOX/copilot.json"
mv "$SANDBOX/copilot.json" "$RESURRECT_DIR/assistant-sessions.json"
run_restore
assert_eq 'conflicting required state root sends no command' '' "$(cat "$TMUX_LOG")"
assert_contains 'conflicting required state root is diagnosed' "$RESTORE_OUTPUT" 'cannot drop COPILOT_HOME'

echo
# This suite is already run on Linux, macOS and the Windows portability canary.
# Keep the shared policy regressions on that same matrix without a new workflow.
if replay_policy_output=$("${TEST_BASH:-bash}" "$REPO_DIR/test/replay-policy-unit-tests.sh" 2>&1); then
	echo "$replay_policy_output"
	pass "shared replay policy suite"
else
	echo "$replay_policy_output"
	fail "shared replay policy suite"
fi
echo "restore unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
