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

echo
echo "restore unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
