#!/usr/bin/env bash
# Claude Code SessionEnd hook — removes the session tracking state file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Install: add to ~/.claude/settings.json under hooks.SessionEnd

set -euo pipefail

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-/tmp/tmux-assistant-resurrect}"

# Remove the state file for this shell's PPID
rm -f "$STATE_DIR/claude-$PPID.json" 2>/dev/null || true
