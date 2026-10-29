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

# shellcheck source=lib-assert.sh
source "$REPO_DIR/test/lib-assert.sh"

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
assert_eq "native-install Claude exec'd by its versioned path is claude" claude \
	"$(detect_tool '/home/u/.local/share/claude/versions/2.1.263 --resume abc')"
assert_eq "awk detector agrees on the versioned Claude path" claude \
	"$(awk_detect_tool '/home/u/.local/share/claude/versions/2.1.263 --resume abc')"
assert_eq "an unrelated versions/ path is not claude" "" \
	"$(detect_tool '/opt/tool/versions/2.1.263 --resume abc')"
assert_eq "awk detector agrees an unrelated versions/ path is not claude" "" \
	"$(awk_detect_tool '/opt/tool/versions/2.1.263 --resume abc')"
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

echo "== Claude transcript cwd fallback =="
CLAUDE_TEST_CONFIG="$SANDBOX/claude-config"
CLAUDE_TEST_CWD='/tmp/work_tree/café'
CLAUDE_TEST_PROJECT="$CLAUDE_TEST_CONFIG/projects/-tmp-work-tree-caf-"
CLAUDE_OLD_SID='11111111-1111-4111-8111-111111111111'
CLAUDE_NEW_SID='22222222-2222-4222-8222-222222222222'
CLAUDE_EMPTY_SID='33333333-3333-4333-8333-333333333333'
CLAUDE_SYMLINK_SID='44444444-4444-4444-8444-444444444444'
mkdir -p "$CLAUDE_TEST_PROJECT"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"old"}}' \
	>"$CLAUDE_TEST_PROJECT/$CLAUDE_OLD_SID.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"new"}}' \
	>"$CLAUDE_TEST_PROJECT/$CLAUDE_NEW_SID.jsonl"
: >"$CLAUDE_TEST_PROJECT/$CLAUDE_EMPTY_SID.jsonl"
touch "$CLAUDE_TEST_PROJECT/$CLAUDE_OLD_SID.jsonl"
touch "$CLAUDE_TEST_PROJECT/$CLAUDE_NEW_SID.jsonl"
touch "$CLAUDE_TEST_PROJECT/$CLAUDE_EMPTY_SID.jsonl"
python3 -c 'import os, sys, time; now = time.time(); os.utime(sys.argv[1], (now - 2, now - 2)); os.utime(sys.argv[2], (now - 1, now - 1))' \
	"$CLAUDE_TEST_PROJECT/$CLAUDE_OLD_SID.jsonl" "$CLAUDE_TEST_PROJECT/$CLAUDE_NEW_SID.jsonl"

assert_eq "Claude cwd fallback is deferred during PID-specific pass" "" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_TEST_CWD" 0)"
assert_eq "Claude cwd fallback picks newest non-empty transcript" "$CLAUDE_NEW_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_TEST_CWD" 1)"
ln -s "$CLAUDE_TEST_PROJECT/$CLAUDE_NEW_SID.jsonl" \
	"$CLAUDE_TEST_PROJECT/$CLAUDE_SYMLINK_SID.jsonl"
touch -h "$CLAUDE_TEST_PROJECT/$CLAUDE_SYMLINK_SID.jsonl" 2>/dev/null || true
assert_eq "Claude cwd fallback ignores a newer transcript symlink" "$CLAUDE_NEW_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_TEST_CWD" 1)"
assert_eq "Claude cwd fallback stays scoped to the exact cwd" "" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude '/tmp/elsewhere' 1)"

USED_CLAUDE_SESSION_IDS=$'\t'"$CLAUDE_NEW_SID"
assert_eq "Claude cwd fallback does not reuse an emitted session" "$CLAUDE_OLD_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_TEST_CWD" 1)"
# shellcheck disable=SC2034 # read by get_claude_session() in the sourced save script
USED_CLAUDE_SESSION_IDS=""
RESERVED_CLAUDE_SESSION_IDS=$'\t'"$CLAUDE_NEW_SID"$'\t'"$CLAUDE_OLD_SID"
assert_eq "Claude cwd fallback does not claim a PID-reserved session" "" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_TEST_CWD" 1)"
# shellcheck disable=SC2034 # read by get_claude_session() in the sourced save script
RESERVED_CLAUDE_SESSION_IDS=""

echo "== Claude exact-owner reservation producer =="
CLAUDE_RESERVE_STATE="$SANDBOX/claude-reserve-state"
CLAUDE_RESERVE_CACHE="$SANDBOX/claude-reserve-cache"
CLAUDE_STATE_SID='77777777-7777-4777-8777-777777777777'
CLAUDE_ARG_SID='88888888-8888-4888-8888-888888888888'
mkdir -p "$CLAUDE_RESERVE_STATE"
printf '%s\n' "{\"session_id\":\"$CLAUDE_STATE_SID\"}" \
	>"$CLAUDE_RESERVE_STATE/claude-12345.json"
: >"$CLAUDE_RESERVE_CACHE"
CLAUDE_RESERVE_MATCHES="pane:0.0"$'\t'"claude"$'\t'"23456"$'\t'"claude --resume $CLAUDE_ARG_SID"$'\t'"/tmp"$'\t'"/dev/ttys001"$'\t'"pane"$'\t'"0"$'\t'"0"
STATE_DIR="$CLAUDE_RESERVE_STATE"
RESERVED_CLAUDE_SESSION_IDS=""
reserve_claude_candidate_sessions "$CLAUDE_RESERVE_MATCHES" $'\x1f' "$CLAUDE_RESERVE_CACHE"
case "$RESERVED_CLAUDE_SESSION_IDS"$'\t' in
*$'\t'"$CLAUDE_STATE_SID"$'\t'*) reservation_state=yes ;;
*) reservation_state=no ;;
esac
case "$RESERVED_CLAUDE_SESSION_IDS"$'\t' in
*$'\t'"$CLAUDE_ARG_SID"$'\t'*) reservation_argv=yes ;;
*) reservation_argv=no ;;
esac
assert_eq "reservation fallback covers state files without a batch cache" yes "$reservation_state"
assert_eq "reservation prepass covers exact argv selectors" yes "$reservation_argv"
# shellcheck disable=SC2034 # read by helpers in the sourced save script
STATE_DIR="$TMUX_ASSISTANT_RESURRECT_DIR"
# shellcheck disable=SC2034 # read by main() in the sourced save script
RESERVED_CLAUDE_SESSION_IDS=""

CLAUDE_RESUMED_CWD='/tmp/resumed-claude-project'
CLAUDE_RESUMED_PROJECT="$CLAUDE_TEST_CONFIG/projects/-tmp-resumed-claude-project"
mkdir -p "$CLAUDE_RESUMED_PROJECT"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"resumed"}}' \
	>"$CLAUDE_RESUMED_PROJECT/$CLAUDE_OLD_SID.jsonl"
touch -t 202001010101 "$CLAUDE_RESUMED_PROJECT/$CLAUDE_OLD_SID.jsonl"
assert_eq "Claude cwd fallback keeps an idle resumed transcript eligible" "$CLAUDE_OLD_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_RESUMED_CWD" 1)"

CLAUDE_ASTRAL_CWD='/tmp/🚀'
CLAUDE_ASTRAL_PROJECT="$CLAUDE_TEST_CONFIG/projects/-tmp---"
CLAUDE_ASTRAL_SID='55555555-5555-4555-8555-555555555555'
mkdir -p "$CLAUDE_ASTRAL_PROJECT"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"astral"}}' \
	>"$CLAUDE_ASTRAL_PROJECT/$CLAUDE_ASTRAL_SID.jsonl"
assert_eq "Claude cwd encoding mirrors JavaScript UTF-16 replacement" "$CLAUDE_ASTRAL_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_ASTRAL_CWD" 1)"

CLAUDE_LONG_CWD='/'
CLAUDE_LONG_PREFIX=''
while [ "${#CLAUDE_LONG_PREFIX}" -lt 205 ]; do
	CLAUDE_LONG_PREFIX="${CLAUDE_LONG_PREFIX}a"
done
CLAUDE_LONG_CWD="${CLAUDE_LONG_CWD}${CLAUDE_LONG_PREFIX}"
CLAUDE_LONG_PREFIX="${CLAUDE_LONG_PREFIX%aaaaaa}"
# Expected key independently calculated from Claude Code's L1o()/GV() source.
CLAUDE_LONG_PROJECT="$CLAUDE_TEST_CONFIG/projects/-${CLAUDE_LONG_PREFIX}-bn8w8e"
CLAUDE_LONG_SID='66666666-6666-4666-8666-666666666666'
mkdir -p "$CLAUDE_LONG_PROJECT"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"long"}}' \
	>"$CLAUDE_LONG_PROJECT/$CLAUDE_LONG_SID.jsonl"
assert_eq "Claude cwd encoding pins the 200-character hash branch" "$CLAUDE_LONG_SID" \
	"$(CLAUDE_CONFIG_DIR="$CLAUDE_TEST_CONFIG" get_claude_session $$ claude "$CLAUDE_LONG_CWD" 1)"

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

# @assistant-resurrect-drop-flags removes user-listed flags with their values,
# in every spelling, and ignores entries that are not option-shaped.
echo "== drop-flags =="
# shellcheck disable=SC2034  # read by extract_cli_args in the sourced save script
DROP_FLAGS='--thinking -t'
assert_eq "drop-flags removes a separate-value flag" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --thinking high --model gpt-4")"
assert_eq "drop-flags removes the = spelling" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --thinking=high --model gpt-4")"
assert_eq "drop-flags removes a short flag with its value" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi -t high --model gpt-4")"
assert_eq "drop-flags leaves unlisted flags alone" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --model gpt-4")"
# shellcheck disable=SC2034
DROP_FLAGS='not-a-flag'
assert_eq "drop-flags ignores an entry that is not option-shaped" \
	"--model gpt-4" \
	"$(extract_cli_args pi "pi --model gpt-4" 2>/dev/null)"
# shellcheck disable=SC2034
DROP_FLAGS=''
assert_eq "drop-flags unset replays the flag" \
	"--thinking high --model gpt-4" \
	"$(extract_cli_args pi "pi --thinking high --model gpt-4")"
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

echo "== claude system-prompt file options keep their path =="
# Help prose can mention a scalar option before a variadic one on the same
# line. Only the option whose own metavar ends in `...` may be classified as
# variadic; otherwise a scalar such as --model can consume a trailing prompt.
assert_eq "Claude variadic discovery does not sweep in other flags on the line" \
	"--disallowedTools --tools" \
	"$(
		_CLAUDE_VARIADIC_FLAGS=""
		export SESSION_VARIADIC_FALLBACK_claude="--disallowedTools"
		_tool_help() { printf '  --model <model>, --tools <tools...>\n'; }
		_claude_variadic_flags
	)"
# --system-prompt-file and --append-system-prompt-file are accepted by claude
# but missing from the option list in `claude --help`, so discovery cannot see
# them and only the static fallback pins them as value-taking. Read as
# booleans, their path becomes the first positional and the filter drops it
# together with the whole tail -- restore then replays a bare
# --append-system-prompt-file and claude eats the next flag as its filename.
# These assertions hold whether or not a claude binary is on PATH: the
# fallback is a superset of what --help exposes.
assert_eq "--append-system-prompt-file keeps its path" \
	"--append-system-prompt-file /tmp/sp.md" \
	"$(extract_cli_args claude "claude --append-system-prompt-file /tmp/sp.md")"
assert_eq "--system-prompt-file keeps its path and the flags after it" \
	"--system-prompt-file /tmp/sp.md --model m" \
	"$(extract_cli_args claude "claude --system-prompt-file /tmp/sp.md --model m")"
# The tail-drop is what makes this more than a cosmetic loss: a mis-read flag
# takes every later option with it, so pin a following flag's survival too.
assert_eq "a flag after the file path is not swallowed with it" \
	"--append-system-prompt-file /tmp/sp.md --model m" \
	"$(extract_cli_args claude "claude --append-system-prompt-file /tmp/sp.md --model m")"
# A genuine positional must still take the tail with it, fix or no fix.
assert_eq "a prompt positional still discards the rest" \
	"--append-system-prompt-file /tmp/sp.md" \
	"$(extract_cli_args claude "claude --append-system-prompt-file /tmp/sp.md hi --model m")"

# --advisor takes a model but is hidden from `claude --help`, so it is pinned
# in the static fallback too. Read as a boolean, "opus" became the first
# positional and the filter dropped it plus the tail, leaving a bare --advisor
# that swallowed the --resume restore appended after it.
assert_eq "--advisor keeps its value" \
	"--model sonnet --advisor opus" \
	"$(extract_cli_args claude "claude --model sonnet --advisor opus")"
assert_eq "a flag after --advisor's value is not swallowed" \
	"--advisor opus --effort high" \
	"$(extract_cli_args claude "claude --advisor opus --effort high")"

# A path with a space in it survives ps as several bare tokens, so the flattened
# form above keeps only the fragment before the space. Claude then exits with
# "Append system prompt file not found: <fragment>" and the pane never resumes.
# /proc keeps the boundary, so on Linux/WSL the option is recognised as
# unrepresentable in a whitespace-joined cli_args and dropped instead -- losing
# the extra system prompt, not the session. Claude also takes a positional
# prompt, so exact argv is the only thing that can tell that case apart from a
# split value; both are asserted here against the same binary.
if [ -r "/proc/$$/cmdline" ]; then
	echo "== claude exact argv (/proc/<pid>/cmdline) =="
	# Mirror the real launcher shape: argv[0] is the interpreter and argv[1] a
	# script path ending in /claude, as the node loader appears.
	mkdir -p "$SANDBOX/launcher" "$SANDBOX/My Prompts"
	printf '#!/usr/bin/env bash\nsleep 45\n' >"$SANDBOX/launcher/claude"
	chmod +x "$SANDBOX/launcher/claude"
	: >"$SANDBOX/My Prompts/sp.md"
	: >"$SANDBOX/sp.md"
	# stdout is redirected: the harness captures this suite in a command
	# substitution, which would otherwise wait on a background job holding the
	# pipe open.
	bash "$SANDBOX/launcher/claude" --append-system-prompt-file \
		"$SANDBOX/My Prompts/sp.md" --model opus >/dev/null 2>&1 &
	SPACED_PID=$!
	bash "$SANDBOX/launcher/claude" --append-system-prompt-file \
		"$SANDBOX/sp.md" write me a haiku --model opus >/dev/null 2>&1 &
	PROMPTED_PID=$!
	# A newline is legal inside one argv element. The exact-argv reader must not
	# turn it into a new argument: the second line can itself look like a
	# permission-widening flag even though it is still part of the file path.
	NEWLINE_PATH="$SANDBOX/sp.md"$'\n''--dangerously-skip-permissions'
	bash "$SANDBOX/launcher/claude" --append-system-prompt-file \
		"$NEWLINE_PATH" --model opus >/dev/null 2>&1 &
	NEWLINE_PID=$!
	bash "$SANDBOX/launcher/claude" --disallowedTools 'Bash(rm -rf /)' \
		--dangerously-skip-permissions --model opus >/dev/null 2>&1 &
	RESTRICTED_PID=$!
	bash "$SANDBOX/launcher/claude" --disallowedTools Bash Write \
		--dangerously-skip-permissions --model opus >/dev/null 2>&1 &
	VARIADIC_PID=$!
	bash "$SANDBOX/launcher/claude" --append-system-prompt-file '' \
		--model opus >/dev/null 2>&1 &
	EMPTY_PID=$!
	bash "$SANDBOX/launcher/claude" --debug --model opus >/dev/null 2>&1 &
	OPTIONAL_PID=$!
	bash "$SANDBOX/launcher/claude" --dangerously-skip-permissions \
		'write a haiku' --permission-mode plan >/dev/null 2>&1 &
	TAIL_RESTRICTED_PID=$!
	sleep 1
	# ps flattens both to the same shape; only cmdline tells them apart.
	assert_eq "a space-bearing path drops its option and keeps the tail" \
		"--model opus" \
		"$(extract_cli_args claude \
			"claude --append-system-prompt-file $SANDBOX/My Prompts/sp.md --model opus" \
			"$SPACED_PID")"
	assert_eq "a real prompt after a valid path keeps the path, drops the tail" \
		"--append-system-prompt-file $SANDBOX/sp.md" \
		"$(extract_cli_args claude \
			"claude --append-system-prompt-file $SANDBOX/sp.md write me a haiku --model opus" \
			"$PROMPTED_PID")"
	assert_eq "a newline inside one value cannot become an injected flag" \
		"--model opus" \
		"$(extract_cli_args claude \
			"claude --append-system-prompt-file $SANDBOX/sp.md --dangerously-skip-permissions --model opus" \
			"$NEWLINE_PID")"
	assert_eq "losing a deny list drops permission-widening replay args" \
		"" \
		"$(extract_cli_args claude \
			"claude --disallowedTools Bash(rm -rf /) --dangerously-skip-permissions --model opus" \
			"$RESTRICTED_PID")"
	case " $(_claude_variadic_flags) " in
	*' --disallowedTools '*) assert_eq "Claude discovers variadic deny lists" yes yes ;;
	*) assert_eq "Claude discovers variadic deny lists" yes no ;;
	esac
	assert_eq "a variadic deny list preserves every exact value" \
		"--disallowedTools Bash Write --dangerously-skip-permissions --model opus" \
		"$(extract_cli_args claude \
			"claude --disallowedTools Bash Write --dangerously-skip-permissions --model opus" \
			"$VARIADIC_PID")"
	assert_eq "an empty value drops its option and keeps the tail" \
		"--model opus" \
		"$(extract_cli_args claude \
			"claude --append-system-prompt-file --model opus" \
			"$EMPTY_PID")"
	assert_eq "an optional value cannot consume the following flag" \
		"--debug --model opus" \
		"$(extract_cli_args claude \
			"claude --debug --model opus" \
			"$OPTIONAL_PID")"
	assert_eq "a restriction after a positional drops widening replay args" \
		"" \
		"$(extract_cli_args claude \
			"claude --dangerously-skip-permissions write a haiku --permission-mode plan" \
			"$TAIL_RESTRICTED_PID")"
	kill "$SPACED_PID" "$PROMPTED_PID" "$NEWLINE_PID" \
		"$RESTRICTED_PID" "$VARIADIC_PID" "$EMPTY_PID" "$OPTIONAL_PID" \
		"$TAIL_RESTRICTED_PID" 2>/dev/null
else
	printf '  [skip] claude exact argv from /proc (not available on this platform)\n'
fi

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
echo "== state roots honor CODEX_HOME and XDG_DATA_HOME =="
# A tmux hook does not inherit the shell profile, so the candidate process's own
# value must win; the hook's environment is next; the documented default last.
ROOT_PROC="$SANDBOX/root-proc"
mkdir -p "$ROOT_PROC/5151" "$ROOT_PROC/5252"
printf 'CODEX_HOME=/srv/codex home\0XDG_DATA_HOME=/srv/data\0' >"$ROOT_PROC/5151/environ"
printf 'PATH=/usr/bin\0' >"$ROOT_PROC/5252/environ"
assert_eq "codex_home reads CODEX_HOME from the process" "/srv/codex home" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" CODEX_HOME=/hook/codex codex_home 5151)"
assert_eq "codex_home falls back to the hook's CODEX_HOME" "/hook/codex" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" CODEX_HOME=/hook/codex codex_home 5252)"
assert_eq "codex_home defaults to ~/.codex" "$HOME/.codex" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" CODEX_HOME='' codex_home 5252)"
assert_eq "codex_home with no pid uses the hook environment" "/hook/codex" \
	"$(CODEX_HOME=/hook/codex codex_home)"
assert_eq "opencode_db_file reads XDG_DATA_HOME from the process" "/srv/data/opencode/opencode.db" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" XDG_DATA_HOME=/hook/data opencode_db_file 5151)"
assert_eq "opencode_db_file falls back to the hook's XDG_DATA_HOME" "/hook/data/opencode/opencode.db" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" XDG_DATA_HOME=/hook/data opencode_db_file 5252)"
assert_eq "opencode_db_file defaults to ~/.local/share" "$HOME/.local/share/opencode/opencode.db" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" XDG_DATA_HOME='' opencode_db_file 5252)"
# The Codex tag lookup must follow the resolved root, not a hardcoded ~/.codex.
CODEX_ALT="$SANDBOX/codex-alt"
mkdir -p "$CODEX_ALT"
printf '{"pid": 5252, "session": "ses_from_alt_home"}\n' >"$CODEX_ALT/session-tags.jsonl"
assert_eq "get_codex_session reads session-tags.jsonl under CODEX_HOME" "ses_from_alt_home" \
	"$(ASSISTANT_PROC_ROOT="$ROOT_PROC" CODEX_HOME="$CODEX_ALT" get_codex_session 5252 "codex" "")"
assert_eq "a hardcoded ~/.codex or opencode.db path no longer exists in the save script" "" \
	"$(grep -nE 'HOME\}?/\.codex|HOME\}?/\.local/share/opencode' "$REPO_DIR/scripts/save-assistant-sessions.sh" |
		grep -vE '^[0-9]*:[[:space:]]*#|CODEX_HOME:-|XDG_DATA_HOME:-' || true)"

echo
echo "== parts rows survive tabs, newlines and pretty JSON =="
# A cwd or prompt can carry a tab or a newline, and the state file's env is
# read as JSON; none of them may split or shift a TSV row.
# emit_session reads state files from the STATE_DIR resolved when the script
# was sourced, which this suite points at its sandbox.
printf '{"session_id":"ses_row","model":"opus","env":{"A":"x\\ty","B":"line1\\nline2"}}\n' >"$STATE_DIR/claude-424242.json"
ROW_PARTS="$SANDBOX/row-parts.tsv"
: >"$ROW_PARTS"
ROW_CWD=$'/tmp/odd\tdir\nsecond line'
(
	# shellcheck disable=SC2034  # read by the sourced emit_session
	PARTS_FILE="$ROW_PARTS" CAPTURE_ENV=''
	get_claude_session() { echo ses_row; }
	emit_session "work:0.0" claude 424242 'claude --verbose' "$ROW_CWD" 1 0
)
rm -f "$STATE_DIR/claude-424242.json"
assert_eq "one emitted session is one row" 1 "$(wc -l <"$ROW_PARTS" | tr -d ' ')"
assert_eq "cwd with a tab and a newline round-trips" "$ROW_CWD" \
	"$(sessions_parts_to_json "$ROW_PARTS" | jq -r '.[0].cwd')"
assert_eq "env read from the state file stays one JSON value" '{"A":"x\ty","B":"line1\nline2"}' \
	"$(sessions_parts_to_json "$ROW_PARTS" | jq -c '.[0].env')"
assert_eq "tsv_row escapes backslash, tab and newline within a column" $'a\\\\b\\tc\\nd\te' \
	"$(tsv_row $'a\\b\tc\nd' e)"
assert_eq "no parts writer bypasses tsv_row" "" \
	"$(grep -nE "printf '%s(\\\\t%s)+\\\\n'" "$REPO_DIR/scripts/save-assistant-sessions.sh" || true)"

echo
echo "== ps field selection =="
# procps-ng 3.3.x (Amazon Linux 2, RHEL/CentOS 7) reads `-o pid=,ppid=` as one
# `pid` column headed ",ppid=", so every process-table walk silently finds
# nothing there. No CI image ships that ps, so pin the spelling statically.
comma_ps=$(grep -rnE -- '[a-z]=,[a-z]+=' "$REPO_DIR/scripts" "$REPO_DIR/hooks" "$REPO_DIR/test" 2>/dev/null |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
assert_eq "no ps -o list joins an empty-header field with a comma" "" "$comma_ps"

# --- repeated options are stripped completely ---------------------------------
# The strip patterns consume the separator on both sides, so with /g the
# separator an adjacent repeat needs has already been eaten and only every
# other occurrence went. _strip_long_opt is used for --attachment, --worktree
# and each discovered session-identity flag, so a survivor is replayed verbatim.
norm_args() { printf '%s' "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }

assert_eq "long opt: single occurrence still stripped" "--dsp" \
	"$(norm_args "$(_strip_long_opt --session-id '--session-id A --dsp')")"
assert_eq "long opt: repeated space form fully stripped" "" \
	"$(norm_args "$(_strip_long_opt --session-id '--session-id A --session-id B')")"
assert_eq "long opt: repeated equals form fully stripped" "" \
	"$(norm_args "$(_strip_long_opt --session-id '--session-id=A --session-id=B')")"
assert_eq "long opt: three in a row fully stripped" "" \
	"$(norm_args "$(_strip_long_opt --session-id '--session-id A --session-id B --session-id C')")"
assert_eq "long opt: repeated --worktree fully stripped" "--keep k" \
	"$(norm_args "$(_strip_long_opt --worktree '--worktree /p --worktree /q --keep k')")"
assert_eq "long opt: a look-alike flag is left alone" "--session-id-extra v --other x" \
	"$(norm_args "$(_strip_long_opt --session-id '--session-id-extra v --other x')")"
assert_eq "long opt: surrounding args survive" "--model m --resume R" \
	"$(norm_args "$(_strip_long_opt --session-id '--model m --session-id A --resume R')")"
assert_eq "short opt: repeated form fully stripped" "" \
	"$(norm_args "$(_strip_short_opt -r '-r A -r B')")"
assert_eq "short opt: single occurrence still stripped" "-x" \
	"$(norm_args "$(_strip_short_opt -r '-r A -x')")"
assert_eq "bool opt: repeated form fully stripped" "--keep" \
	"$(norm_args "$(_strip_bool_opt --cloud '--cloud --cloud --keep')")"
assert_eq "bool opt: single occurrence still stripped" "--keep" \
	"$(norm_args "$(_strip_bool_opt --cloud '--cloud --keep')")"
assert_eq "bool opt: a look-alike flag is left alone" "--cloudy --keep" \
	"$(norm_args "$(_strip_bool_opt --cloud '--cloudy --keep')")"

# An empty or whitespace-only flag is the class of input the t loop made worse:
# "(^| )( |$)" matches a lone space and puts a lone space back, so it never
# reaches a fixpoint, where /g returned at once. No caller passes one today, so
# this guards the helpers rather than a call site. ulimit -t caps the CPU of
# the subshell and the sed it starts, so an unguarded helper fails these on
# empty output instead of stalling CI; where RLIMIT_CPU cannot be set the
# ulimit is a no-op and it would stall instead, which is why the guard belongs
# in the helper and is not left to the test.
strip_bounded() { (ulimit -t 5 2>/dev/null; "$@") 2>/dev/null; }

assert_eq "long opt: an empty flag returns the args untouched" "x y " \
	"$(strip_bounded _strip_long_opt '' 'x y ')"
assert_eq "short opt: an empty flag returns the args untouched" "x  y" \
	"$(strip_bounded _strip_short_opt '' 'x  y')"
assert_eq "bool opt: an empty flag returns the args untouched" " " \
	"$(strip_bounded _strip_bool_opt '' ' ')"
assert_eq "long opt: a whitespace-only flag returns the args untouched" "x y " \
	"$(strip_bounded _strip_long_opt ' ' 'x y ')"
assert_eq "short opt: a whitespace-only flag returns the args untouched" " " \
	"$(strip_bounded _strip_short_opt ' ' ' ')"
assert_eq "bool opt: a whitespace-only flag returns the args untouched" " " \
	"$(strip_bounded _strip_bool_opt ' ' ' ')"

# --- bench-save-hook.sh must stay isolated from the developer's own server ----
# Static guards, like the -F record guards in target-resolution-unit-tests.sh:
# the script cannot be executed here to prove this, so pin the two properties
# that make it safe to run outside Docker. tmux ignores TMUX_TMPDIR both when
# the directory does not exist yet and whenever $TMUX is set, so the ordering
# and the unset are each load-bearing, and -S is the backstop for both.
BENCH_SH="$REPO_DIR/test/bench-save-hook.sh"
# Executable lines only. Every guard below reads this, not the file: a guard
# that a commented-out command satisfies is a guard that cannot fail, and the
# isolation it claims to pin would be gone with all of them still green.
bench_code() { grep -vE '^[[:space:]]*#' "$BENCH_SH"; }
bench_line() { bench_code | grep -n "$1" | head -1 | cut -d: -f1; }

assert_eq "bench: TMUX is unset before anything runs" "yes" \
	"$(bench_code | grep -x 'unset TMUX' >/dev/null && echo yes || echo no)"

bench_mkdir=$(bench_line '^mkdir -p "\$HOME')
bench_trap=$(bench_line '^trap cleanup EXIT$')
bench_unset=$(bench_line '^unset TMUX$')
assert_eq "bench: the isolation dir exists before the EXIT trap is armed" "yes" \
	"$([ -n "$bench_mkdir" ] && [ -n "$bench_trap" ] && [ "$bench_mkdir" -lt "$bench_trap" ] && echo yes || echo no)"
assert_eq "bench: TMUX is unset before the EXIT trap is armed" "yes" \
	"$([ -n "$bench_unset" ] && [ -n "$bench_trap" ] && [ "$bench_unset" -lt "$bench_trap" ] && echo yes || echo no)"

# Every tmux invocation must carry an explicit -S. Nothing else is filtered
# out: an earlier TMUX_TMPDIR/TMUX_ASSISTANT exemption here matched no line on
# this file and would have waved through exactly the shape it was meant to
# catch -- `TMUX_TMPDIR="$x" tmux kill-server`.
bench_bare=$(bench_code | grep -n 'tmux ' | grep -v 'tmux -S ' || true)
assert_eq "bench: no tmux call without an explicit -S" "" "$bench_bare"

# A private socket is not a private server: tmux still reads the system file
# and $XDG_CONFIG_HOME/tmux/tmux.conf, neither of which the sandboxed $HOME
# covers. Pinning every call rather than the one that currently starts the
# server is the only form of this that a call added above the loop -- a bare
# `tmux -S "$BENCH_SOCKET" start-server`, say -- cannot walk past.
bench_unpinned=$(bench_code | grep -n 'tmux -S ' | grep -v -- '-f /dev/null' || true)
assert_eq "bench: every tmux call pins -f /dev/null" "" "$bench_unpinned"

# The explicit -S skips make_label(), so nothing else creates the socket's
# parent. Without this the first new-session fails with ENOENT and the whole
# benchmark aborts under set -e -- which the guards above cannot see.
assert_eq "bench: the socket's parent directory is created, at 0700" "yes" \
	"$(bench_code | grep 'mkdir -m 700 "\$TMUX_TMPDIR/tmux-\$(id -u)"' >/dev/null && echo yes || echo no)"
bench_sockdir=$(bench_line 'mkdir -m 700 "\$TMUX_TMPDIR')
assert_eq "bench: that directory exists before the EXIT trap is armed" "yes" \
	"$([ -n "$bench_sockdir" ] && [ -n "$bench_trap" ] && [ "$bench_sockdir" -lt "$bench_trap" ] && echo yes || echo no)"

assert_eq "bench: the cleanup kill is socket-scoped" "yes" \
	"$(bench_code | grep 'tmux -S "\$BENCH_SOCKET" .*kill-server' >/dev/null && echo yes || echo no)"
# Every 2>, &> and >& on the kill, not just the >/dev/null 2>&1 that was there:
# hiding the kill's diagnostics is what made a misroute invisible in the first
# place, and bash's combined forms hide it just as well. A redirection moved
# onto a continuation line would slip past, which is why the kill is kept on
# one line.
assert_eq "bench: the cleanup kill keeps its stderr" "" \
	"$(bench_code | grep 'kill-server' | grep -E '2>|&>|>&' || true)"

echo
echo "save hardening unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
