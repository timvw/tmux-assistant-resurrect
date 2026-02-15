#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session ID to a trackable file.
# Receives JSON on stdin with session_id, cwd, etc.
# Keyed by PPID (Claude Code's PID, since Claude spawns this hook).
#
# Install: add to ~/.claude/settings.json under hooks.SessionStart

set -euo pipefail

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-/tmp/tmux-assistant-resurrect}"
mkdir -p "$STATE_DIR"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$SESSION_ID" ]; then
	exit 0
fi

# Write session file keyed by PPID (Claude Code's PID when it spawns this hook)
cat >"$STATE_DIR/claude-$PPID.json" <<EOF
{
  "tool": "claude",
  "session_id": "$SESSION_ID",
  "cwd": "$CWD",
  "ppid": $PPID,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
