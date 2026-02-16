#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session ID to a trackable file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Claude may spawn this hook via an intermediate process (e.g., sh -c 'bash hook.sh'),
# so $PPID is not necessarily the main Claude process. We walk up the process tree
# to find the ancestor whose command is 'claude', and key the state file by that PID.
#
# Install: add to ~/.claude/settings.json under hooks.SessionStart

set -euo pipefail

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
mkdir -p -m 0700 "$STATE_DIR"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$SESSION_ID" ]; then
	exit 0
fi

# Walk up the process tree from $PPID to find the main Claude process.
# On some systems $PPID IS the Claude PID; on others there's an intermediate
# shell (sh -c) between Claude and the hook.
find_claude_pid() {
	local pid="$PPID"
	local max_depth=5
	while [ "$max_depth" -gt 0 ] && [ "$pid" -gt 1 ]; do
		local cmd
		cmd=$(ps -o comm= -p "$pid" 2>/dev/null || true)
		case "$cmd" in
		claude | */claude)
			echo "$pid"
			return
			;;
		esac
		# Move to parent
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		max_depth=$((max_depth - 1))
	done
	# Fallback: use $PPID if we couldn't find 'claude' in the ancestry
	echo "$PPID"
}

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
