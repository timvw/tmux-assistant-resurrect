#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session ID to a trackable file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Install: add to ~/.claude/settings.json under hooks.SessionStart

set -euo pipefail

# Source shared find_claude_pid() helper
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-claude-pid.sh
source "$HOOK_DIR/lib-claude-pid.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
mkdir -p -m 0700 "$STATE_DIR"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$SESSION_ID" ]; then
	exit 0
fi

CLAUDE_PID=$(find_claude_pid)

# Write session file keyed by the Claude process PID.
# Use jq to ensure proper JSON escaping of all values.
STATE_FILE="$STATE_DIR/claude-$CLAUDE_PID.json"
if ! jq -n \
	--arg tool "claude" \
	--arg session_id "$SESSION_ID" \
	--arg cwd "$CWD" \
	--argjson ppid "$CLAUDE_PID" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{tool: $tool, session_id: $session_id, cwd: $cwd, ppid: $ppid, timestamp: $timestamp}' \
	>"$STATE_FILE" 2>/dev/null; then
	echo "tmux-assistant-resurrect: failed to write state file $STATE_FILE (permission denied?)" >&2
fi
