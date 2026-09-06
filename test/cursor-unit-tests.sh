#!/usr/bin/env bash
# Hermetic unit tests for Cursor Agent CLI detection, hook tracking, and argv
# extraction. No Cursor login or binary is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR"

# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"
# shellcheck source=../scripts/save-assistant-sessions.sh
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1

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

echo "== detect_tool =="
assert_eq "legacy cursor-agent binary" "cursor" "$(detect_tool 'cursor-agent --resume 750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2')"
assert_eq "current agent binary" "cursor" "$(detect_tool 'agent --use-system-ca /opt/cursor/index.js --trust')"
assert_eq "absolute current agent binary" "cursor" \
	"$(detect_tool '/home/me/.local/bin/agent --use-system-ca /opt/cursor/index.js --model auto')"
assert_eq "unrelated generic agent is ignored" "" "$(detect_tool '/usr/local/bin/agent --model auto')"
assert_eq "agent-like argument is not Cursor" "" "$(detect_tool 'vim /tmp/cursor-agent')"
awk_detect_tool() {
	printf '%s\n' "$1" | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk"
}
assert_eq "shell and awk detectors agree on current agent" "cursor" \
	"$(awk_detect_tool 'agent --use-system-ca /opt/cursor/index.js --trust')"

echo "== get_cursor_session =="
CURSOR_STATE="$TMUX_ASSISTANT_RESURRECT_DIR/cursor-4242.json"
printf '%s\n' '{"session_id":"750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2"}' >"$CURSOR_STATE"
assert_eq "hook state is authoritative" "750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2" \
	"$(get_cursor_session 4242 'agent --resume other-id')"
assert_eq "resume arg is restart fallback" "8a8fbf72-344c-4264-acd4-2c251cfe54c0" \
	"$(get_cursor_session 9999 'cursor-agent --resume=8a8fbf72-344c-4264-acd4-2c251cfe54c0')"
assert_eq "bare agent without hook state stays unresolved" "" "$(get_cursor_session 9999 'agent')"
rm -f "$CURSOR_STATE"
assert_eq "current Cursor executable name is retained" "agent" \
	"$(cursor_binary_from_args '/home/me/.local/bin/agent --use-system-ca /opt/cursor/index.js --trust')"
assert_eq "legacy Cursor executable name is retained" "cursor-agent" \
	"$(cursor_binary_from_args '/home/me/.local/bin/cursor-agent --trust')"

echo "== extract_cli_args =="
assert_eq "strip resume and prompt, preserve mode/model/sandbox" \
	"--mode plan --model auto --sandbox enabled" \
	"$(extract_cli_args cursor 'agent --use-system-ca /opt/cursor/index.js --mode plan --resume 750b1c55-f1b2-4ff1-804e-9c38d1b2c7e2 --model auto --sandbox enabled explain this')"
assert_eq "strip continue and credential" "--force" \
	"$(extract_cli_args cursor 'cursor-agent --continue --api-key secret --force')"

echo "== Cursor SessionStart hook =="
FAKE_BIN="$SANDBOX/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/ps" <<'PS'
#!/usr/bin/env bash
pid=""
previous=""
for argument in "$@"; do
    [ "$previous" = "-p" ] && pid="$argument"
    previous="$argument"
done
case " $* " in
    *' args= '*)
        if [ "${FAKE_PS_CHAIN:-}" = "1" ] && [ "$pid" != "4242" ]; then
            printf '/bin/sh\n'
        else
            printf '%s\n' "${FAKE_PS_ARGS:-/opt/cursor/agent --use-system-ca /opt/cursor/index.js --trust}"
        fi
        ;;
    *' ppid= '*)
        if [ "${FAKE_PS_CHAIN:-}" = "1" ] && [ "$pid" != "4242" ]; then
            printf '4242\n'
        else
            printf '1\n'
        fi
        ;;
esac
PS
cat >"$FAKE_BIN/tmux" <<'TMUX'
#!/usr/bin/env bash
if [ "${1:-}" = "show-option" ]; then
    printf '%s' "${FAKE_TMUX_OPTION:-CURSOR_TEST_ENV}"
fi
TMUX
chmod +x "$FAKE_BIN/ps" "$FAKE_BIN/tmux"

touch "$SANDBOX/GLOB_LEAK"
(cd "$SANDBOX" && FAKE_TMUX_OPTION='* CURSOR_TEST_ENV' \
	GLOB_LEAK='must not be captured' PATH="$FAKE_BIN:$PATH" \
	CURSOR_TEST_ENV='captured value' \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh") <<'JSON'
{"session_id":"9a8fbf72-344c-4264-acd4-2c251cfe54c1","model":"auto","hook_event_name":"sessionStart","extra":"preserved"}
JSON

CURSOR_HOOK_STATE=$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f -print -quit)
assert_eq "hook keys state by Cursor PID" "9a8fbf72-344c-4264-acd4-2c251cfe54c1" \
	"$(jq -r '.session_id' "$CURSOR_HOOK_STATE" 2>/dev/null)"
assert_eq "hook preserves full input" "preserved" "$(jq -r '.extra' "$CURSOR_HOOK_STATE" 2>/dev/null)"
assert_eq "hook captures configured env" "captured value" "$(jq -r '.env.CURSOR_TEST_ENV' "$CURSOR_HOOK_STATE" 2>/dev/null)"
assert_eq "capture-env does not expand globs from the hook cwd" "absent" \
	"$(jq -r 'if .env | has("GLOB_LEAK") then "present" else "absent" end' "$CURSOR_HOOK_STATE" 2>/dev/null)"

rm -f "$CURSOR_HOOK_STATE"
FAKE_PS_ARGS='node /opt/cursor/cursor-agent --trust' PATH="$FAKE_BIN:$PATH" \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh" <<'JSON'
{"session_id":"aa8fbf72-344c-4264-acd4-2c251cfe54c2","hook_event_name":"sessionStart"}
JSON
CURSOR_HOOK_STATE=$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f -print -quit)
assert_eq "hook finds interpreter-launched cursor-agent ancestor" \
	"aa8fbf72-344c-4264-acd4-2c251cfe54c2" \
	"$(jq -r '.session_id' "$CURSOR_HOOK_STATE" 2>/dev/null)"

rm -f "$CURSOR_HOOK_STATE"
FAKE_PS_ARGS='/Applications/Cursor.app/Contents/MacOS/Cursor' PATH="$FAKE_BIN:$PATH" \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh" <<'JSON'
{"session_id":"ba8fbf72-344c-4264-acd4-2c251cfe54c3","hook_event_name":"sessionStart"}
JSON
assert_eq "desktop Cursor ancestry writes no CLI state" "0" \
	"$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f | wc -l | tr -d ' ')"

FAKE_PS_ARGS='/usr/local/bin/agent --model auto' PATH="$FAKE_BIN:$PATH" \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh" <<'JSON'
{"session_id":"ca8fbf72-344c-4264-acd4-2c251cfe54c4","hook_event_name":"sessionStart"}
JSON
assert_eq "generic agent ancestry writes no Cursor state" "0" \
	"$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f | wc -l | tr -d ' ')"

if FAKE_PS_ARGS='bash' PATH="$FAKE_BIN:$PATH" \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh" <<'JSON'
{"session_id":"ce8fbf72-344c-4264-acd4-2c251cfe54c4","hook_event_name":"sessionStart"}
JSON
then
	assert_eq "bare interpreter ancestor fails closed without aborting the hook" "0" \
		"$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f | wc -l | tr -d ' ')"
else
	assert_eq "bare interpreter ancestor fails closed without aborting the hook" "success" "nonzero exit"
fi

FAKE_PS_CHAIN=1 FAKE_PS_ARGS='/opt/cursor/cursor-agent --trust' PATH="$FAKE_BIN:$PATH" \
	"${BASH:-bash}" "$REPO_DIR/hooks/cursor-session-track.sh" <<'JSON'
{"session_id":"da8fbf72-344c-4264-acd4-2c251cfe54c5","hook_event_name":"sessionStart"}
JSON
CURSOR_HOOK_STATE=$(find "$TMUX_ASSISTANT_RESURRECT_DIR" -name 'cursor-*.json' -type f -print -quit)
assert_eq "hook walks through an intermediate shell ancestor" \
	"da8fbf72-344c-4264-acd4-2c251cfe54c5" \
	"$(jq -r '.session_id' "$CURSOR_HOOK_STATE" 2>/dev/null)"

echo
echo "cursor unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
