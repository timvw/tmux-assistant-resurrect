#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session ID to a trackable file.
# Receives JSON on stdin with session_id, cwd, etc.
# Keyed by PPID (Claude Code's PID, since Claude spawns this hook).
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

# Write session file keyed by PPID (Claude Code's PID when it spawns this hook)
# Use jq to ensure proper JSON escaping of all values.
STATE_FILE="$STATE_DIR/claude-$PPID.json"
if ! jq -n \
	--arg tool "claude" \
	--arg session_id "$SESSION_ID" \
	--arg cwd "$CWD" \
	--argjson ppid "$PPID" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{tool: $tool, session_id: $session_id, cwd: $cwd, ppid: $ppid, timestamp: $timestamp}' \
	>"$STATE_FILE" 2>/dev/null; then
	echo "tmux-assistant-resurrect: failed to write state file $STATE_FILE (permission denied?)" >&2
fi
