#!/usr/bin/env bash
# Claude Code SessionEnd hook — removes the session tracking state file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Uses the same ancestor walk as the SessionStart hook to find the Claude PID.
#
# Install: add to ~/.claude/settings.json under hooks.SessionEnd

set -euo pipefail

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"

# Walk up the process tree from $PPID to find the main Claude process.
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
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		max_depth=$((max_depth - 1))
	done
	echo "$PPID"
}

CLAUDE_PID=$(find_claude_pid)
rm -f "$STATE_DIR/claude-$CLAUDE_PID.json" 2>/dev/null || true
