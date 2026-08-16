#!/usr/bin/env bash
# Claude Code SessionEnd hook — removes the session tracking state file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Install: add to ~/.claude/settings.json under hooks.SessionEnd

set -euo pipefail

# Claude settings are profile-wide, but this hook owns only tmux sessions.
# A non-tmux session must not remove state belonging to a tmux-hosted Claude.
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
	cat >/dev/null
	exit 0
fi

# Source shared find_claude_pid() helper
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-claude-pid.sh
source "$HOOK_DIR/lib-claude-pid.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"

CLAUDE_PID=$(find_claude_pid)
rm -f "$STATE_DIR/claude-$CLAUDE_PID.json" 2>/dev/null || true
