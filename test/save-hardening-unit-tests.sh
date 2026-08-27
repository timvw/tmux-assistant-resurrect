#!/usr/bin/env bash
# Hermetic regressions for save-side process detection and filesystem handling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export TMUX_RESURRECT_DIR="$SANDBOX/source-resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/source-state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR"

# Keep option lookups independent of the developer's live tmux server.
tmux() { return 1; }

# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"
# shellcheck source=../scripts/save-assistant-sessions.sh
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1
set +e

PASS=0
FAIL=0
assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
	fi
}

awk_detect_tool() {
	printf '%s\n' "$1" | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk"
}

echo "== executable-token detection =="
for line in \
	'vim /tmp/claude notes' \
	'python3 worker.py --output /opt/bin/copilot' \
	'cat /tmp/opencode' \
	'watch tail /tmp/codex' \
	'logger /tmp/pi' \
	'printf /tmp/omp' \
	'less /tmp/grok'; do
	assert_eq "shell ignores assistant-looking argument: $line" "" "$(detect_tool "$line")"
	assert_eq "awk ignores assistant-looking argument: $line" "" "$(awk_detect_tool "$line")"
done
assert_eq "known Node launcher remains detectable" "copilot" \
	"$(detect_tool 'node /opt/homebrew/bin/copilot --no-auto-update')"
assert_eq "known shell launcher remains detectable" "opencode" \
	"$(detect_tool '/bin/bash /usr/local/bin/opencode -s ses_456')"
assert_eq "prompt text does not trigger OpenCode worker exclusion" "opencode" \
	"$(detect_tool 'opencode --prompt explain opencode run mode')"
assert_eq "prompt text does not trigger OMP worker exclusion" "omp" \
	"$(detect_tool 'omp --prompt explain __omp_worker_mode')"
assert_eq "shell and awk detectors retain parity" \
	"$(detect_tool 'opencode --prompt explain opencode run mode')" \
	"$(awk_detect_tool 'opencode --prompt explain opencode run mode')"
assert_eq "awk detector clears argv state portably between records" opencode \
	"$(printf 'opencode run worker\nopencode\n' | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk")"

echo "== order-independent descendant walk =="
snapshot=$' 300 200 claude --resume ses_child_first\n 200 100 node wrapper.js\n 100 1 bash'
assert_eq "child listed before its parent is still found" "300" \
	"$(pane_has_assistant 100 "$snapshot")"
cycle_snapshot=$' 300 200 claude --resume ses_cycle\n 200 300 node wrapper.js\n 100 1 bash'
assert_eq "malformed process cycle terminates without a false match" "" \
	"$(pane_has_assistant 100 "$cycle_snapshot")"

echo "== exact used-session membership =="
USED_CODEX_SESSION_IDS=""
register_codex_session_id session-long
register_codex_session_id session
register_codex_session_id session-long
assert_eq "Codex IDs that are substrings remain distinct" \
	$'\tsession-long\tsession' "$USED_CODEX_SESSION_IDS"
USED_PI_SESSION_IDS=""
register_pi_session_id 'id-*'
register_pi_session_id id-value
register_pi_session_id 'id-*'
assert_eq "Pi IDs are compared literally, not as glob patterns" \
	$'\tid-*\tid-value' "$USED_PI_SESSION_IDS"
USED_OMP_SESSION_IDS=""
register_omp_session_id abc
register_omp_session_id bc
assert_eq "OMP IDs that are substrings remain distinct" \
	$'\tabc\tbc' "$USED_OMP_SESSION_IDS"

echo "== unpredictable private save files =="
RUN_DIR="$SANDBOX/run"
STUB_DIR="$SANDBOX/bin"
VICTIM="$SANDBOX/victim"
mkdir -p "$RUN_DIR" "$STUB_DIR"
printf 'do not overwrite\n' >"$VICTIM"

cat >"$STUB_DIR/tmux" <<'STUB'
#!/bin/sh
if [ ! -e "$TMUX_RESURRECT_DIR/.prepared" ]; then
	mkdir -p "$TMUX_RESURRECT_DIR"
	printf 'old log\n' >"$TMUX_RESURRECT_DIR/assistant-save.log"
	ln -s "$TEST_VICTIM" "$TMUX_RESURRECT_DIR/assistant-save.log.tmp"
	ln -s "$TEST_VICTIM" "$TMUX_RESURRECT_DIR/assistant-sessions.json.tmp.$PPID"
	: >"$TMUX_RESURRECT_DIR/.prepared"
fi
case "$*" in
*list-panes*)
	if [ -n "${MOCK_SWAP_LOG_PATH:-}" ] && [ ! -e "${MOCK_SWAP_LOG_MARKER:-}" ]; then
		: >"$MOCK_SWAP_LOG_MARKER"
		rm -f "$MOCK_SWAP_LOG_PATH"
		ln -s "$MOCK_SWAP_LOG_TARGET" "$MOCK_SWAP_LOG_PATH"
	fi
	exit 0
	;;
*) exit 1 ;;
esac
STUB
cat >"$STUB_DIR/ps" <<'STUB'
#!/bin/sh
printf ' 99999 1 sleep 1\n'
STUB
chmod +x "$STUB_DIR/tmux" "$STUB_DIR/ps"

if env PATH="$STUB_DIR:$PATH" \
	TMUX_RESURRECT_DIR="$RUN_DIR" \
	TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/run-state" \
	ASSISTANT_RESURRECT_SAVE_TIMEOUT=0 TEST_VICTIM="$VICTIM" \
	"${TEST_BASH:-bash}" "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1; then
	assert_eq "predictable temp-name symlinks cannot clobber another file" \
		"do not overwrite" "$(sed -n '1p' "$VICTIM")"
	assert_eq "save still publishes valid JSON" "0" \
		"$(jq '.sessions | length' "$RUN_DIR/assistant-sessions.json" 2>/dev/null)"
	case "$(uname -s 2>/dev/null)" in
	MINGW* | MSYS* | CYGWIN*) ;;
	Darwin)
		assert_eq "sidecar is owner-only" "600" "$(stat -f '%Lp' "$RUN_DIR/assistant-sessions.json")"
		assert_eq "save log is owner-only" "600" "$(stat -f '%Lp' "$RUN_DIR/assistant-save.log")"
		;;
	*)
		assert_eq "sidecar is owner-only" "600" "$(stat -c '%a' "$RUN_DIR/assistant-sessions.json")"
		assert_eq "save log is owner-only" "600" "$(stat -c '%a' "$RUN_DIR/assistant-save.log")"
		;;
	esac
else
	FAIL=$((FAIL + 1))
	printf '  [FAIL] hermetic save invocation failed\n'
fi

SYMLINK_RUN="$SANDBOX/symlink-log-run"
SYMLINK_VICTIM="$SANDBOX/dangling-log-target"
mkdir -p "$SYMLINK_RUN"
ln -s "$SYMLINK_VICTIM" "$SYMLINK_RUN/assistant-save.log"
: >"$SYMLINK_RUN/.prepared"
symlink_log_stderr=$(env PATH="$STUB_DIR:$PATH" \
	TMUX_RESURRECT_DIR="$SYMLINK_RUN" \
	TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/symlink-log-state" \
	ASSISTANT_RESURRECT_SAVE_TIMEOUT=0 TEST_VICTIM="$VICTIM" \
	"${TEST_BASH:-bash}" "$REPO_DIR/scripts/save-assistant-sessions.sh" 2>&1 >/dev/null)
assert_eq "dangling save-log symlink target is not created" no \
	"$([ -e "$SYMLINK_VICTIM" ] && printf yes || printf no)"
case "$symlink_log_stderr" in
*'refusing symlinked save log'*) assert_eq "symlink refusal is diagnosed on stderr" yes yes ;;
*) assert_eq "symlink refusal is diagnosed on stderr" yes no ;;
esac

RACE_RUN="$SANDBOX/raced-log-run"
RACE_VICTIM="$SANDBOX/raced-log-target"
RACE_MARKER="$SANDBOX/raced-log-marker"
mkdir -p "$RACE_RUN"
: >"$RACE_RUN/.prepared"
printf 'old log\n' >"$RACE_RUN/assistant-save.log"
printf 'do not overwrite\n' >"$RACE_VICTIM"
env PATH="$STUB_DIR:$PATH" \
	TMUX_RESURRECT_DIR="$RACE_RUN" \
	TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/raced-log-state" \
	ASSISTANT_RESURRECT_SAVE_TIMEOUT=0 TEST_VICTIM="$VICTIM" \
	MOCK_SWAP_LOG_PATH="$RACE_RUN/assistant-save.log" \
	MOCK_SWAP_LOG_TARGET="$RACE_VICTIM" MOCK_SWAP_LOG_MARKER="$RACE_MARKER" \
	"${TEST_BASH:-bash}" "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1
assert_eq "post-open symlink swap cannot redirect save log writes" \
	"do not overwrite" "$(cat "$RACE_VICTIM")"

echo "== unpredictable archive replacement =="
ARCHIVE_DIR="$SANDBOX/archive-case"
mkdir -p "$ARCHIVE_DIR/source/pane_contents"
printf 'assistant output\n' >"$ARCHIVE_DIR/source/pane_contents/pane-test:0.0"
printf 'other output\n' >"$ARCHIVE_DIR/source/pane_contents/pane-other:0.0"
tar cf - -C "$ARCHIVE_DIR/source" ./pane_contents/ | gzip >"$ARCHIVE_DIR/pane_contents.tar.gz"
OUTPUT_FILE="$ARCHIVE_DIR/assistant-sessions.json"
# shellcheck disable=SC2034 # read by strip_assistant_pane_contents() from the sourced save script
RESURRECT_DIR="$ARCHIVE_DIR"
# shellcheck disable=SC2034 # read by log() from the sourced save script
LOG_FILE="$ARCHIVE_DIR/assistant-save.log"
printf '%s\n' '{"sessions":[{"pane":"test:0.0"}],"relaunch":[]}' >"$OUTPUT_FILE"
printf 'archive victim\n' >"$ARCHIVE_DIR/victim"
ln -s "$ARCHIVE_DIR/victim" "$ARCHIVE_DIR/pane_contents.tar.gz.tmp"
strip_assistant_pane_contents >/dev/null 2>&1
assert_eq "predictable archive temp symlink is not followed" "archive victim" \
	"$(sed -n '1p' "$ARCHIVE_DIR/victim")"
archive_members=$(gzip -dc "$ARCHIVE_DIR/pane_contents.tar.gz" | tar tf -)
case "$archive_members" in
*pane-other:0.0*) assert_eq "non-assistant archive member is retained" yes yes ;;
*) assert_eq "non-assistant archive member is retained" yes no ;;
esac
case "$archive_members" in
*pane-test:0.0*) assert_eq "assistant archive member is removed" no yes ;;
*) assert_eq "assistant archive member is removed" no no ;;
esac

log_error_file="$SANDBOX/log-write-error"
exec 9>&-
LOG_ENABLED=1
log "forced closed descriptor" 2>"$log_error_file"
assert_eq "save logging disables itself after a descriptor write failure" 0 "$LOG_ENABLED"
case "$(cat "$log_error_file")" in
*'cannot write save log'*) assert_eq "save log write failure is reported once" yes yes ;;
*) assert_eq "save log write failure is reported once" yes no ;;
esac

echo "== credential flags are stripped from cli_args =="
# extract_cli_args must remove credential-bearing flags while keeping
# surrounding non-credential flags intact. Session flag discovery is
# unavailable here (no mock binary), so session flags remain — the test
# focuses on the credential blocklist.
assert_eq "--api-key VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --api-key sk-xxx --model gpt-4")"
assert_eq "--api-key=VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --api-key=sk-xxx --model gpt-4")"
assert_eq "--token VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --token tok-secret --model gpt-4")"
assert_eq "--token=VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --token=tok-secret --model gpt-4")"
assert_eq "--password VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --password s3cret --model gpt-4")"
assert_eq "--secret-key VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --secret-key abc123 --model gpt-4")"
assert_eq "--auth-token VALUE form is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --auth-token bearer-xyz --model gpt-4")"
assert_eq "non-credential flags around credential survive" \
	"--verbose --model gpt-4 --debug" \
	"$(extract_cli_args pi "pi --verbose --api-key sk-xxx --model gpt-4 --debug")"
assert_eq "multiple credential flags are all stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --api-key sk-xxx --token tok-yyy --model gpt-4")"
assert_eq "credential flag at end is stripped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --model gpt-4 --api-key sk-xxx")"
# ps flattens argv before this runs, so a value containing spaces arrives as
# several tokens. Consuming only one would persist the remainder of the secret.
assert_eq "multi-word credential value is fully consumed" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --api-key correct horse battery staple --model gpt-4")"
assert_eq "multi-word value at end leaves nothing behind" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --model gpt-4 --password hunter two three")"
# The token right after the flag is the value even when it looks like a flag.
assert_eq "dash-leading credential value is still consumed" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --api-key -sk-dashy --model gpt-4")"
# --secret-env-vars matches the blocklist by shape but carries variable NAMES,
# not a secret. Stripping it would silently disable the user's redaction.
assert_eq "--secret-env-vars survives the credential filter" \
	"--secret-env-vars TOKEN --model gpt-4" \
	"$(extract_cli_args copilot "copilot --secret-env-vars TOKEN --model gpt-4")"
assert_eq "--secret-env-vars=VALUE form survives too" \
	"--secret-env-vars=TOKEN --model gpt-4" \
	"$(extract_cli_args copilot "copilot --secret-env-vars=TOKEN --model gpt-4")"
assert_eq "a real secret flag alongside it is still stripped" \
	"--secret-env-vars TOKEN --model gpt-4" \
	"$(extract_cli_args copilot "copilot --secret-env-vars TOKEN --api-key sk-xxx --model gpt-4")"

echo "== session-less relaunch diagnostics =="
# A pane launched with an inline key is precisely the case that reaches the
# session-less path, and relaunch_shape_ok() rejects it -- so the rejection
# message was the one place the key still reached assistant-save.log verbatim.
# log() writes to stderr and fd 9 only, so capturing stderr sees every line.
_relaunch_stderr() {
	# Brace form so the intent is explicit: drop stdout, then hand stderr to the
	# command substitution. Only the diagnostics are under test here.
	{ RELAUNCH_ENABLED=on \
		handle_sessionless_relaunch 'sess:0.0' pi 4242 "$1" /tmp 1 >/dev/null || true; } 2>&1
}
_holds() { case "$2" in *"$1"*) printf 'yes\n' ;; *) printf 'no\n' ;; esac; }

relaunch_diag=$(_relaunch_stderr 'pi --api-key sk-RELAUNCHSECRET agents')
assert_eq "rejected relaunch cmd does not log the key" "no" \
	"$(_holds 'sk-RELAUNCHSECRET' "$relaunch_diag")"
assert_eq "rejected relaunch cmd still names the dropped flag" "yes" \
	"$(_holds '--api-key' "$relaunch_diag")"
# A command with nothing to strip must be reported unchanged, or the diagnostic
# stops being useful for the ordinary rejection cases.
relaunch_diag=$(_relaunch_stderr 'pi -p summarize this')
assert_eq "clean relaunch cmd is reported verbatim" "yes" \
	"$(_holds 'relaunch shape rejected: pi -p summarize this' "$relaunch_diag")"

echo "== is_credential_flag shared helper =="
_cred_rc() { is_credential_flag "$1" && echo yes || echo no; }
assert_eq "--api-key is credential" "yes" "$(_cred_rc "--api-key")"
assert_eq "--api-key-file is credential" "yes" "$(_cred_rc "--api-key-file")"
assert_eq "--api_key is credential" "yes" "$(_cred_rc "--api_key")"
assert_eq "--token is credential" "yes" "$(_cred_rc "--token")"
assert_eq "--token-file is credential" "yes" "$(_cred_rc "--token-file")"
assert_eq "--secret is credential" "yes" "$(_cred_rc "--secret")"
assert_eq "--secret-key is credential" "yes" "$(_cred_rc "--secret-key")"
assert_eq "--password is credential" "yes" "$(_cred_rc "--password")"
assert_eq "--password-file is credential" "yes" "$(_cred_rc "--password-file")"
assert_eq "--auth-token is credential" "yes" "$(_cred_rc "--auth-token")"
assert_eq "--model is not credential" "no" "$(_cred_rc "--model")"
assert_eq "--verbose is not credential" "no" "$(_cred_rc "--verbose")"
assert_eq "--debug is not credential" "no" "$(_cred_rc "--debug")"

echo
echo "save hardening unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
