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

case "${1:-}" in
list-panes)
	printf '%s\n' "${MOCK_PANES:-}"
	;;
list-clients)
	printf 'client\n'
	;;
display-message)
	pane="${3:-}"
	case "${5:-}" in
	'#{pane_current_command}')
		shell_name=$(lookup_shell "$pane")
		printf '%s\n' "${shell_name:-bash}"
		;;
	'#{pane_pid}') printf '%s\n' "${MOCK_PANE_PID:-999999}" ;;
	esac
	;;
show-option)
	case "${3:-}" in
	@assistant-resurrect-capture-env) printf '%s\n' "${MOCK_CAPTURE_ENV:-}" ;;
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
		"$MOCK_EXEC_SHELL" -fc "$command_text"
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
	for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} >"$MOCK_ASSISTANT_MARKER"
MOCK_CLAUDE

chmod +x "$MOCK_BIN/sleep" "$MOCK_BIN/tmux" "$MOCK_BIN/claude"

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
assert_contains "captured env uses the portable env launcher" "$csh_tmux_log" "env SAFE='env\\!choice' claude"
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

	# With no environment wrapper, restore deliberately uses csh/tcsh's
	# `command` builtin to bypass aliases. Exercise that separate construction.
	export MOCK_CAPTURE_ENV=''
	jq -n '{sessions:[{
	  pane:"csh-test:0.0", session_name:"csh-test", window_index:"0", pane_index:"0",
	  tool:"claude", session_id:"sid-no-env", cwd:"", env:{}
	}]}' >"$RESURRECT_DIR/assistant-sessions.json"
	run_restore
	marker=$(cat "$ASSISTANT_MARKER" 2>/dev/null || true)
	assert_contains "tcsh accepts the no-env command builtin form" "$(cat "$TMUX_LOG")" \
		"send-keys|%1|command claude --resume 'sid-no-env'"
	assert_contains "tcsh executes the no-env resume command" "$marker" "arg=sid-no-env"
else
	pass "tcsh unavailable; portable command shape still covered"
fi
export MOCK_EXEC_SHELL=''
assert_eq "restore log is owner-only" "600" "$(file_mode "$RESURRECT_DIR/assistant-restore.log")"

echo "== Nushell-specific command construction =="
nu_cwd="$SANDBOX/nu cwd"
mkdir -p "$nu_cwd"
export MOCK_PANES='%9|0|0|nu-test'
export MOCK_SHELLS='%9|nu'
export MOCK_CAPTURE_ENV='SAFE'
jq -n --arg cwd "$nu_cwd" '{sessions:[{
  pane:"nu-test:0.0", session_name:"nu-test", window_index:"0", pane_index:"0",
  tool:"claude", session_id:"sid-nu", cwd:$cwd, env:{SAFE:"nu-value"}
}]}' >"$RESURRECT_DIR/assistant-sessions.json"
run_restore
nu_tmux_log=$(cat "$TMUX_LOG")
assert_contains "Nushell uses its external-command marker" "$nu_tmux_log" "^claude --resume 'sid-nu'"
assert_contains "Nushell restores env with with-env" "$nu_tmux_log" "with-env { SAFE: 'nu-value' }"
assert_contains "Nushell cwd uses statement sequencing" "$nu_tmux_log" "cd '$nu_cwd'; with-env"
assert_not_contains "Nushell cwd does not use unsupported &&" "$nu_tmux_log" " && "

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
assert_contains "embedded newline is escaped in logs" "$restore_log" 'claude\nFORGED-LOG-LINE'
forged_lines=$(grep -c '^FORGED-LOG-LINE' "$RESURRECT_DIR/assistant-restore.log" || true)
assert_eq "sidecar text cannot forge a physical log line" "0" "$forged_lines"

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

echo
echo "restore unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
