#!/usr/bin/env bash
# Integration tests for tmux-assistant-resurrect.
# Runs inside Docker with mock assistant binaries.
set -euo pipefail

REPO_DIR="$HOME/tmux-assistant-resurrect"
PASS=0
FAIL=0
ERRORS=""

# --- Helpers ---

pass() {
	PASS=$((PASS + 1))
	echo "  PASS: $1"
}

fail() {
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  FAIL: $1"
	echo "  FAIL: $1"
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

# --- Test 2: Save — detect mock assistants in tmux panes ---

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

# Create a Claude hook state file for test-claude pane's shell PID
claude_pane_shell_pid=$(tmux display-message -t test-claude -p '#{pane_pid}')
STATE_DIR="/tmp/tmux-assistant-resurrect"
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/claude-${claude_pane_shell_pid}.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_claude_test_123",
  "ppid": $claude_pane_shell_pid,
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

# --- Test 5b: detect_tool() unit tests ---

echo ""
echo "=== Test 5b: detect_tool() pattern matching ==="
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

if [ "$FAIL" -gt 0 ]; then
	echo -e "\nFailures:$ERRORS"
	echo ""
	exit 1
fi

echo ""
exit 0
