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
*list-panes*) exit 0 ;;
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

echo
echo "save hardening unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
