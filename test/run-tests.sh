#!/usr/bin/env bash
# Integration tests for tmux-assistant-resurrect.
# Runs inside Docker with real assistant CLI binaries.
set -euo pipefail

REPO_DIR="$HOME/tmux-assistant-resurrect"
JUNIT_FILE="${JUNIT_FILE:-/tmp/test-results/junit.xml}"
PASS=0
FAIL=0
ERRORS=""

# --- JUnit XML tracking ---

CURRENT_SUITE=""
JUNIT_CASES=""

# XML-escape special characters in text
xml_escape() {
	printf '%s' "$1" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g; s/'/\&apos;/g"
}

suite() {
	CURRENT_SUITE="$1"
}

junit_pass() {
	local name
	name=$(xml_escape "$1")
	local suite
	suite=$(xml_escape "$CURRENT_SUITE")
	JUNIT_CASES="${JUNIT_CASES}<testcase classname=\"${suite}\" name=\"${name}\"/>"
}

junit_fail() {
	local name
	name=$(xml_escape "$1")
	local message
	message=$(xml_escape "$2")
	local suite
	suite=$(xml_escape "$CURRENT_SUITE")
	JUNIT_CASES="${JUNIT_CASES}<testcase classname=\"${suite}\" name=\"${name}\"><failure message=\"${message}\"/></testcase>"
}

write_junit() {
	local total=$((PASS + FAIL))
	mkdir -p "$(dirname "$JUNIT_FILE")"
	cat >"$JUNIT_FILE" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="${total}" failures="${FAIL}">
  <testsuite name="tmux-assistant-resurrect" tests="${total}" failures="${FAIL}">
    ${JUNIT_CASES}
  </testsuite>
</testsuites>
JEOF
	echo "JUnit XML written to $JUNIT_FILE"
}

# --- Helpers ---

pass() {
	PASS=$((PASS + 1))
	echo "  PASS: $1"
	junit_pass "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  FAIL: $1"
	echo "  FAIL: $1"
	junit_fail "$1" "$1"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF "$needle"; then
		pass "$desc"
	else
		fail "$desc (expected to contain '$needle')"
	fi
}

assert_file_exists() {
	local desc="$1" path="$2"
	if [ -f "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file not found: $path)"
	fi
}

assert_file_not_exists() {
	local desc="$1" path="$2"
	if [ ! -f "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file should not exist: $path)"
	fi
}

# --- Test 1: Installation ---

suite "install"
echo ""
echo "=== Test 1: just install ==="
echo ""

cd "$REPO_DIR"
just install 2>&1

# Verify TPM installed
if [ -d "$HOME/.tmux/plugins/tpm" ]; then
	pass "TPM installed"
else
	fail "TPM not installed"
fi

# Verify Claude hooks in settings.json
assert_file_exists "Claude settings.json created" "$HOME/.claude/settings.json"

hook_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Claude SessionStart hook present" "1" "$hook_count"

cleanup_count=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json")
assert_eq "Claude SessionEnd hook present" "1" "$cleanup_count"

# Verify OpenCode plugin symlinked
if [ -L "$HOME/.config/opencode/plugins/session-tracker.js" ]; then
	pass "OpenCode plugin symlinked"
else
	fail "OpenCode plugin not symlinked"
fi

# Verify tmux.conf configured
assert_file_exists "tmux.conf exists" "$HOME/.tmux.conf"
assert_contains "tmux.conf sources resurrect config" "$(cat "$HOME/.tmux.conf")" "resurrect-assistants.conf"

# Verify idempotent install (run again, should not duplicate)
just install 2>&1 >/dev/null

hook_count_after=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Install is idempotent (no duplicate hooks)" "1" "$hook_count_after"

# --- Test 2: Save — detect assistants in tmux panes ---

suite "save"
echo ""
echo "=== Test 2: save (process detection + session IDs) ==="
echo ""

# Start a tmux server
tmux new-session -d -s test-claude -c /tmp
tmux new-session -d -s test-opencode -c /tmp
tmux new-session -d -s test-codex -c /tmp
tmux new-session -d -s test-opencode-nosid -c /tmp
tmux new-session -d -s test-lsp -c /tmp

# Launch mock assistants inside tmux panes
# Claude: just a bare claude process (session ID comes from hook state file)
tmux send-keys -t test-claude "claude --resume ses_claude_test_123" Enter
# OpenCode: with -s flag (detected from process args)
tmux send-keys -t test-opencode "opencode -s ses_opencode_test_456" Enter
# Codex: bare process (session ID comes from session-tags.jsonl)
tmux send-keys -t test-codex "codex resume ses_codex_test_789" Enter
# OpenCode without -s flag (no session ID available — should log warning)
tmux send-keys -t test-opencode-nosid "opencode" Enter
# OpenCode LSP subprocess (should be excluded from detection)
tmux send-keys -t test-lsp "opencode run pyright-langserver.js" Enter

# Give processes time to start
sleep 2

# Create a Claude hook state file keyed by the Claude child PID
# (When Claude runs the hook, hook's $PPID = Claude PID, so the save script
#  looks for claude-{child_pid}.json where child_pid = the claude process PID)
claude_pane_shell_pid=$(tmux display-message -t test-claude -p '#{pane_pid}')
claude_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$claude_pane_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')
STATE_DIR="/tmp/tmux-assistant-resurrect"
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/claude-${claude_child_pid}.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_claude_test_123",
  "ppid": $claude_child_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
EOF

# Create a Codex session-tags.jsonl entry
codex_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$(tmux display-message -t test-codex -p '#{pane_pid}')" '$2 == ppid && /codex/ {print $1; exit}')
mkdir -p "$HOME/.codex"
echo "{\"pid\": ${codex_child_pid}, \"session\": \"ses_codex_test_789\", \"host\": \"test\", \"started_at\": \"2026-01-01T00:00:00Z\"}" >"$HOME/.codex/session-tags.jsonl"

# Run save
just save 2>&1

# Verify output file
SAVED="$HOME/.tmux/resurrect/assistant-sessions.json"
assert_file_exists "assistant-sessions.json created" "$SAVED"

session_count=$(jq '.sessions | length' "$SAVED")
# We expect: claude (1) + opencode with -s (1) + codex (1) = 3 with session IDs
# opencode-nosid detected but no session ID, so excluded from sessions array
# lsp subprocess should be excluded entirely
if [ "$session_count" -ge 3 ]; then
	pass "Detected at least 3 assistant sessions (got $session_count)"
else
	fail "Expected at least 3 sessions, got $session_count"
fi

# Verify Claude was detected with correct session ID
claude_sid=$(jq -r '.sessions[] | select(.tool == "claude") | .session_id' "$SAVED")
assert_eq "Claude session ID extracted" "ses_claude_test_123" "$claude_sid"

# Verify OpenCode was detected with correct session ID (from -s arg)
opencode_sid=$(jq -r '[.sessions[] | select(.tool == "opencode" and .session_id != "")] | first | .session_id' "$SAVED")
assert_eq "OpenCode session ID extracted from -s arg" "ses_opencode_test_456" "$opencode_sid"

# Verify Codex was detected with correct session ID (from session-tags.jsonl)
codex_sid=$(jq -r '.sessions[] | select(.tool == "codex") | .session_id' "$SAVED")
assert_eq "Codex session ID extracted from session-tags.jsonl" "ses_codex_test_789" "$codex_sid"

# Verify LSP subprocess was excluded
lsp_count=$(jq '[.sessions[] | select(.pane | contains("test-lsp"))] | length' "$SAVED")
assert_eq "LSP subprocess excluded from detection" "0" "$lsp_count"

# Verify the log mentions the opencode without session ID
LOG="$HOME/.tmux/resurrect/assistant-save.log"
if grep -q "no session ID available" "$LOG"; then
	pass "Log warns about opencode without session ID"
else
	fail "Expected log warning about missing session ID"
fi

# --- Test 3: Restore — sends correct resume commands ---

suite "restore"
echo ""
echo "=== Test 3: restore (resume commands) ==="
echo ""

# Kill all mock assistants first (so panes are empty shells)
tmux send-keys -t test-claude C-c
tmux send-keys -t test-opencode C-c
tmux send-keys -t test-codex C-c
tmux send-keys -t test-opencode-nosid C-c
tmux send-keys -t test-lsp C-c
sleep 1

# Run restore
just restore 2>&1

# Give restore time to send commands (it has sleep 1 between each + sleep 2 at start)
sleep $((session_count * 2 + 3))

# Verify restore log
RESTORE_LOG="$HOME/.tmux/resurrect/assistant-restore.log"
assert_file_exists "Restore log created" "$RESTORE_LOG"

restore_log_content=$(cat "$RESTORE_LOG")
assert_contains "Restore log mentions claude" "$restore_log_content" "restoring claude"
assert_contains "Restore log mentions opencode" "$restore_log_content" "restoring opencode"
assert_contains "Restore log mentions codex" "$restore_log_content" "restoring codex"

# Verify the restore log contains the correct resume commands
# (pane content is unreliable — real CLIs take over the terminal and clear it)
assert_contains "Restore sent claude --resume" "$restore_log_content" "ses_claude_test_123"
assert_contains "Restore sent opencode -s" "$restore_log_content" "ses_opencode_test_456"
assert_contains "Restore sent codex resume" "$restore_log_content" "ses_codex_test_789"

# --- Test 4: Uninstall ---

suite "uninstall"
echo ""
echo "=== Test 4: just uninstall ==="
echo ""

just uninstall 2>&1

# Verify Claude hooks removed
remaining_hooks=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Claude hooks removed after uninstall" "0" "$remaining_hooks"

# Verify OpenCode plugin removed
assert_file_not_exists "OpenCode plugin removed" "$HOME/.config/opencode/plugins/session-tracker.js"

# Verify tmux.conf cleaned
if grep -qF "resurrect-assistants.conf" "$HOME/.tmux.conf" 2>/dev/null; then
	fail "tmux.conf still references resurrect-assistants.conf"
else
	pass "tmux.conf cleaned"
fi

# --- Test 5: Claude hooks (SessionStart / SessionEnd) ---

suite "hooks"
echo ""
echo "=== Test 5: Claude hook scripts ==="
echo ""

# Test SessionStart hook: feed it JSON on stdin, verify state file
export TMUX_ASSISTANT_RESURRECT_DIR="/tmp/tmux-assistant-resurrect-test5"
mkdir -p "$TMUX_ASSISTANT_RESURRECT_DIR"
echo '{"session_id": "ses_hook_test", "cwd": "/tmp/project"}' | bash "$REPO_DIR/hooks/claude-session-track.sh"

state_file="$TMUX_ASSISTANT_RESURRECT_DIR/claude-$$.json"
assert_file_exists "SessionStart hook creates state file" "$state_file"

if [ -f "$state_file" ]; then
	hook_sid=$(jq -r '.session_id' "$state_file")
	assert_eq "SessionStart hook writes correct session ID" "ses_hook_test" "$hook_sid"
fi

# Test SessionEnd hook: should remove the state file
echo '{}' | bash "$REPO_DIR/hooks/claude-session-cleanup.sh"
assert_file_not_exists "SessionEnd hook removes state file" "$state_file"

unset TMUX_ASSISTANT_RESURRECT_DIR

suite "regression"
# --- Test 5b: Claude state file keyed by child PID (regression) ---
#
# The SessionStart hook's $PPID = Claude's PID (not the shell PID), because
# Claude spawns the hook. The save script must look up state files by the
# Claude child PID. Previously the save script used the shell PID, which
# never matched — session IDs were silently lost.

echo ""
echo "=== Test 5b: Claude state file lookup by child PID (regression) ==="
echo ""

# Set up a fresh tmux session with a Claude process
tmux new-session -d -s test-claude-pid -c /tmp
tmux send-keys -t test-claude-pid "claude --resume ses_pid_test" Enter
sleep 2

claude_pid_test_shell=$(tmux display-message -t test-claude-pid -p '#{pane_pid}')
claude_pid_test_child=$(ps -eo pid=,ppid=,args= | awk -v ppid="$claude_pid_test_shell" '$2 == ppid && /claude/ {print $1; exit}')

# Sanity: make sure we found the child
if [ -n "$claude_pid_test_child" ]; then
	pass "Found Claude child PID ($claude_pid_test_child) under shell PID ($claude_pid_test_shell)"
else
	fail "Could not find Claude child PID under shell $claude_pid_test_shell"
fi

PID_TEST_STATE_DIR="/tmp/tmux-assistant-resurrect"
mkdir -p "$PID_TEST_STATE_DIR"

# Clean up any prior state files for these PIDs
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json" "$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json"

# Create state file keyed by CHILD PID (correct — matches how the hook works)
cat >"$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json" <<CEOF
{
  "tool": "claude",
  "session_id": "ses_child_pid_test",
  "ppid": $claude_pid_test_child,
  "timestamp": "2026-01-01T00:00:00Z"
}
CEOF

# Run save and check that the session ID is picked up
rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

child_pid_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-pid")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Save finds state file keyed by Claude child PID" "ses_child_pid_test" "$child_pid_sid"

# --- Test 5c: State file keyed by shell PID must NOT match (regression) ---
#
# If someone (or a bug) creates a state file keyed by the shell PID instead
# of the Claude child PID, the save script must NOT pick it up via the state
# file path. The session ID may still be found via --resume in process args
# (the chicken-and-egg fallback), but it must NOT come from the wrong file.

echo ""
echo "=== Test 5c: State file keyed by shell PID must NOT match (regression) ==="
echo ""

# Remove the correct (child-keyed) state file
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json"

# Create state file keyed by SHELL PID (incorrect — the old bug)
cat >"$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json" <<SEOF
{
  "tool": "claude",
  "session_id": "ses_shell_pid_WRONG",
  "ppid": $claude_pid_test_shell,
  "timestamp": "2026-01-01T00:00:00Z"
}
SEOF

# Run save — should NOT pick up the shell-keyed file's session ID
rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

shell_pid_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-pid")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
if [ "$shell_pid_sid" = "ses_shell_pid_WRONG" ]; then
	fail "Save incorrectly matched state file keyed by shell PID (regression!)"
else
	pass "Save correctly ignores state file keyed by shell PID"
fi

# The session ID may still be found from --resume in process args (the
# chicken-and-egg fallback). That's fine — the key assertion is that the
# WRONG file's ID was not used.
if [ "$shell_pid_sid" = "ses_pid_test" ]; then
	pass "Fallback correctly found session ID from --resume args instead"
else
	# No args fallback available — should log warning
	if grep -q "test-claude-pid.*no session ID available" "$HOME/.tmux/resurrect/assistant-save.log"; then
		pass "Log correctly reports no session ID for shell-PID-keyed state"
	else
		fail "Expected either args fallback or log warning for test-claude-pid"
	fi
fi

# Clean up test state files and session
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json"
tmux send-keys -t test-claude-pid C-c
sleep 1
tmux kill-session -t test-claude-pid 2>/dev/null || true

# --- Test 5c2: Chicken-and-egg — session ID extraction unit tests ---
#
# These test the extraction functions directly, without needing live processes.
# Claude Code overwrites its process title, so --resume isn't visible in `ps`
# for real Claude. But the fallback code works when args ARE preserved (e.g.,
# shell wrappers, or future tools). We test both extraction methods.

echo ""
echo "=== Test 5c2: Session ID extraction unit tests (chicken-and-egg) ==="
echo ""

# Source the extraction functions from the save script
eval "$(sed -n '/^get_claude_session()/,/^}/p' "$REPO_DIR/scripts/save-assistant-sessions.sh")"
eval "$(sed -n '/^get_codex_session()/,/^}/p' "$REPO_DIR/scripts/save-assistant-sessions.sh")"
eval "$(sed -n '/^get_opencode_session()/,/^}/p' "$REPO_DIR/scripts/save-assistant-sessions.sh")"

# --- Claude: --resume arg fallback ---
# Method 2: extract session ID from --resume in process args
assert_eq "Claude --resume extraction" "ses_abc_123" "$(get_claude_session 99999 "claude --resume ses_abc_123")"
assert_eq "Claude --resume with path" "ses_abc_123" "$(get_claude_session 99999 "/usr/bin/claude --resume ses_abc_123")"
assert_eq "Claude bare (no --resume)" "" "$(get_claude_session 99999 "claude")"
assert_eq "Claude --resume with UUID" "a1b2c3d4-e5f6-7890-abcd-ef1234567890" "$(get_claude_session 99999 "claude --resume a1b2c3d4-e5f6-7890-abcd-ef1234567890")"

# --- Claude: state file takes priority over args ---
UNIT_STATE_DIR=$(mktemp -d)
STATE_DIR="$UNIT_STATE_DIR"
cat >"$UNIT_STATE_DIR/claude-12345.json" <<UEOF
{"tool":"claude","session_id":"ses_from_hook","ppid":12345,"timestamp":"2026-01-01T00:00:00Z"}
UEOF
assert_eq "Claude state file beats --resume arg" "ses_from_hook" "$(get_claude_session 12345 "claude --resume ses_from_args")"
rm -rf "$UNIT_STATE_DIR"

# --- Claude: corrupt state file falls through to args ---
UNIT_STATE_DIR=$(mktemp -d)
STATE_DIR="$UNIT_STATE_DIR"
echo "NOT JSON" >"$UNIT_STATE_DIR/claude-12345.json"
assert_eq "Claude corrupt state file falls through to args" "ses_fallback" "$(get_claude_session 12345 "claude --resume ses_fallback")"
rm -rf "$UNIT_STATE_DIR"

# --- Claude: empty state file falls through to args ---
UNIT_STATE_DIR=$(mktemp -d)
STATE_DIR="$UNIT_STATE_DIR"
echo '{}' >"$UNIT_STATE_DIR/claude-12345.json"
assert_eq "Claude empty state file falls through to args" "ses_fallback2" "$(get_claude_session 12345 "claude --resume ses_fallback2")"
rm -rf "$UNIT_STATE_DIR"

# Reset STATE_DIR
STATE_DIR="/tmp/tmux-assistant-resurrect"

# --- Codex: resume arg fallback ---
assert_eq "Codex resume extraction" "ses_codex_789" "$(get_codex_session 99999 "codex resume ses_codex_789")"
assert_eq "Codex resume with path" "ses_codex_789" "$(get_codex_session 99999 "/usr/bin/codex resume ses_codex_789")"
assert_eq "Codex bare (no resume)" "" "$(get_codex_session 99999 "codex")"

# --- OpenCode: -s and --session arg extraction ---
assert_eq "OpenCode -s extraction" "ses_oc_456" "$(get_opencode_session 99999 "opencode -s ses_oc_456")"
assert_eq "OpenCode --session extraction" "ses_oc_789" "$(get_opencode_session 99999 "opencode --session ses_oc_789")"
assert_eq "OpenCode bare (no -s)" "" "$(get_opencode_session 99999 "opencode")"

# --- Test 5c3: Claude state file takes priority over --resume arg ---
#
# If both a state file and --resume arg exist, the state file should win
# because the user may have switched sessions inside the TUI after launch.

echo ""
echo "=== Test 5c3: Claude state file takes priority over --resume arg ==="
echo ""

tmux new-session -d -s test-claude-priority -c /tmp
tmux send-keys -t test-claude-priority "claude --resume ses_args_old" Enter
sleep 2

priority_shell_pid=$(tmux display-message -t test-claude-priority -p '#{pane_pid}')
priority_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$priority_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')

# Create a state file with a DIFFERENT session ID (simulating a session switch)
cat >"$PID_TEST_STATE_DIR/claude-${priority_child_pid}.json" <<PEOF
{
  "tool": "claude",
  "session_id": "ses_hook_newer",
  "ppid": $priority_child_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
PEOF

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

priority_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-priority")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "State file session ID takes priority over --resume arg" "ses_hook_newer" "$priority_sid"

rm -f "$PID_TEST_STATE_DIR/claude-${priority_child_pid}.json"
tmux send-keys -t test-claude-priority C-c
sleep 1
tmux kill-session -t test-claude-priority 2>/dev/null || true

# --- Test 5c4: Codex resume arg fallback (chicken-and-egg) ---
#
# After restore, Codex is launched as `codex resume <session_id>`. Even
# without a session-tags.jsonl entry, the save script should extract the
# session ID from the process args.

echo ""
echo "=== Test 5c4: Codex resume arg fallback (chicken-and-egg) ==="
echo ""

tmux new-session -d -s test-codex-resume -c /tmp
tmux send-keys -t test-codex-resume "codex resume ses_codex_from_args" Enter
sleep 2

# Make sure NO session-tags.jsonl entry exists for this PID
rm -f "$HOME/.codex/session-tags.jsonl"

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

codex_resume_sid=$(jq -r '.sessions[] | select(.pane | contains("test-codex-resume")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Codex resume arg fallback extracts session ID" "ses_codex_from_args" "$codex_resume_sid"

tmux send-keys -t test-codex-resume C-c
sleep 1
tmux kill-session -t test-codex-resume 2>/dev/null || true

# --- Test 5c5: Corrupt/empty state file doesn't crash save ---
#
# If a state file is corrupt (not valid JSON) or empty, the save script
# should not crash — it should fall through gracefully.
# Note: Claude Code overwrites its process title, so --resume args are NOT
# visible in `ps`. The unit tests (5c2) verify the args fallback in isolation.

echo ""
echo "=== Test 5c5: Corrupt state file doesn't crash save ==="
echo ""

tmux new-session -d -s test-corrupt -c /tmp
tmux send-keys -t test-corrupt "claude" Enter
sleep 2

corrupt_shell_pid=$(tmux display-message -t test-corrupt -p '#{pane_pid}')
corrupt_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$corrupt_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')

# Write a corrupt (non-JSON) state file
echo "THIS IS NOT JSON" >"$PID_TEST_STATE_DIR/claude-${corrupt_child_pid}.json"

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
save_exit_code=0
just save 2>&1 || save_exit_code=$?

assert_eq "Save doesn't crash on corrupt state file" "0" "$save_exit_code"

# Claude is detected but neither state file (corrupt) nor args (title overwritten) yield an ID
# Verify the save script logged the warning rather than crashing
if grep -q "test-corrupt.*no session ID available" "$HOME/.tmux/resurrect/assistant-save.log"; then
	pass "Save gracefully handles corrupt state file"
else
	fail "Expected log warning about no session ID for corrupt state file pane"
fi

rm -f "$PID_TEST_STATE_DIR/claude-${corrupt_child_pid}.json"
tmux send-keys -t test-corrupt C-c
sleep 1
tmux kill-session -t test-corrupt 2>/dev/null || true

# --- Test 5d: detect_tool() unit tests ---

suite "detect_tool"
echo ""
echo "=== Test 5d: detect_tool() pattern matching ==="
echo ""

# Source detect_tool from the save script (extract the function)
eval "$(sed -n '/^detect_tool()/,/^}/p' "$REPO_DIR/scripts/save-assistant-sessions.sh")"

# Bare names (no path) — how native binaries appear on Linux
assert_eq "detect bare 'claude'" "claude" "$(detect_tool "claude")"
assert_eq "detect bare 'opencode'" "opencode" "$(detect_tool "opencode")"
assert_eq "detect bare 'codex'" "codex" "$(detect_tool "codex")"

# Bare names with arguments
assert_eq "detect 'claude --resume ses_123'" "claude" "$(detect_tool "claude --resume ses_123")"
assert_eq "detect 'opencode -s ses_456'" "opencode" "$(detect_tool "opencode -s ses_456")"
assert_eq "detect 'codex resume ses_789'" "codex" "$(detect_tool "codex resume ses_789")"

# Full paths (how they appear on macOS or via shebang)
assert_eq "detect '/usr/local/bin/claude'" "claude" "$(detect_tool "/usr/local/bin/claude")"
assert_eq "detect '/opt/homebrew/bin/opencode -s ses_456'" "opencode" "$(detect_tool "/opt/homebrew/bin/opencode -s ses_456")"
assert_eq "detect '/bin/bash /usr/local/bin/opencode -s ses_456'" "opencode" "$(detect_tool "/bin/bash /usr/local/bin/opencode -s ses_456")"

# LSP subprocess exclusion
assert_eq "exclude 'opencode run pyright'" "" "$(detect_tool "opencode run pyright-langserver.js")"
assert_eq "exclude '/usr/bin/opencode run pyright'" "" "$(detect_tool "/usr/bin/opencode run pyright-langserver.js")"

# Non-matches
assert_eq "ignore 'bash'" "" "$(detect_tool "bash")"
assert_eq "ignore 'vim'" "" "$(detect_tool "vim")"
assert_eq "ignore 'node server.js'" "" "$(detect_tool "node server.js")"

# --- Test 6: Clean recipe ---

suite "clean"
echo ""
echo "=== Test 6: just clean ==="
echo ""

# Re-install for the clean test
just install 2>&1 >/dev/null

# Create a stale state file with a dead PID
STATE_DIR="/tmp/tmux-assistant-resurrect"
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/claude-99999.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_stale",
  "ppid": 99999,
  "timestamp": "2025-01-01T00:00:00Z"
}
EOF

clean_output=$(just clean 2>&1)
assert_contains "Clean removes stale files" "$clean_output" "Cleaned"
assert_file_not_exists "Stale state file removed" "$STATE_DIR/claude-99999.json"

# --- Test 7: TPM plugin entry point ---

suite "tpm"
echo ""
echo "=== Test 7: TPM plugin entry point (.tmux file) ==="
echo ""

# Clean up from previous tests — remove claude hooks and opencode plugin
just uninstall 2>&1 >/dev/null

# Remove claude settings entirely to test from scratch
rm -f "$HOME/.claude/settings.json"
rm -rf "$HOME/.config/opencode/plugins"

# Run the TPM plugin entry point (simulates what TPM does on prefix+I)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"

# Verify Claude hooks installed
assert_file_exists "TPM: Claude settings.json created" "$HOME/.claude/settings.json"
tpm_hook_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Claude SessionStart hook present" "1" "$tpm_hook_count"
tpm_cleanup_count=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Claude SessionEnd hook present" "1" "$tpm_cleanup_count"

# Verify OpenCode plugin symlinked
if [ -L "$HOME/.config/opencode/plugins/session-tracker.js" ]; then
	pass "TPM: OpenCode plugin symlinked"
else
	fail "TPM: OpenCode plugin not symlinked"
fi

# Verify idempotent (run again, no duplicates)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"
tpm_hook_count_after=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Idempotent (no duplicate hooks)" "1" "$tpm_hook_count_after"

# --- Summary ---

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

write_junit

if [ "$FAIL" -gt 0 ]; then
	echo -e "\nFailures:$ERRORS"
	echo ""
	exit 1
fi

echo ""
exit 0
