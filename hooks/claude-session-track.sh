#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session context to a trackable file.
# Receives JSON on stdin with session_id, cwd, model, source, permission_mode,
# transcript_path, hook_event_name, and optionally agent_type.
#
# The full stdin JSON is merged with our added fields (tool, ppid, timestamp,
# env) so any new fields Claude adds in future versions are captured
# automatically without code changes.
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

if [ -z "$SESSION_ID" ]; then
	exit 0
fi

CLAUDE_PID=$(find_claude_pid)

# Build env object: always capture TMUX_PANE and SHELL, plus user-configured
# vars from the tmux option @assistant-resurrect-capture-env (space-separated).
ENV_JSON=$(jq -n --arg tmux_pane "${TMUX_PANE:-}" --arg shell "${SHELL:-}" \
	'{tmux_pane: $tmux_pane, shell: $shell}')

CAPTURE_ENV=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
for var in $CAPTURE_ENV; do
	# shellcheck disable=SC2086
	ENV_JSON=$(echo "$ENV_JSON" | jq --arg k "$var" --arg v "${!var:-}" '. + {($k): $v}')
done

# Merge the full stdin JSON with our added fields + env.
# This preserves all fields Claude sends (model, source, permission_mode, etc.)
# and adds tool metadata for the save/restore scripts.
STATE_FILE="$STATE_DIR/claude-$CLAUDE_PID.json"
if ! echo "$INPUT" | jq \
	--arg tool "claude" \
	--argjson ppid "$CLAUDE_PID" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--argjson env "$ENV_JSON" \
	'. + {tool: $tool, ppid: $ppid, timestamp: $timestamp, env: $env}' \
	>"$STATE_FILE" 2>/dev/null; then
	echo "tmux-assistant-resurrect: failed to write state file $STATE_FILE (permission denied?)" >&2
fi
