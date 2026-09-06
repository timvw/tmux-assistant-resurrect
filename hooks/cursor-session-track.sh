#!/usr/bin/env bash
# Cursor sessionStart hook — persist the stable conversation/session ID keyed
# by the owning Cursor Agent CLI PID. The same hook may run in Cursor Desktop;
# lib-cursor-pid.sh rejects that ancestry so desktop chats are never recorded.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-cursor-pid.sh
source "$HOOK_DIR/lib-cursor-pid.sh"
# shellcheck source=../scripts/lib-detect.sh
source "$HOOK_DIR/../scripts/lib-detect.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -er \
	'objects | (.session_id // .conversation_id) | select(type == "string" and length > 0)' \
	2>/dev/null || true)
[ -n "$SESSION_ID" ] || exit 0

CURSOR_PID=$(find_cursor_pid || true)
[ -n "$CURSOR_PID" ] || exit 0

STATE_DIR="$(assistant_state_dir)"
ensure_assistant_state_dir "$STATE_DIR"

ENV_JSON=$(jq -n --arg tmux_pane "${TMUX_PANE:-}" --arg shell "${SHELL:-}" \
	'{tmux_pane: $tmux_pane, shell: $shell}')
CAPTURE_ENV=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
set -f
for var in $CAPTURE_ENV; do
	[[ "$var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
	NEXT_ENV_JSON=$(printf '%s' "$ENV_JSON" | jq --arg k "$var" --arg v "${!var:-}" \
		'. + {($k): $v}' 2>/dev/null || true)
	[ -z "$NEXT_ENV_JSON" ] || ENV_JSON="$NEXT_ENV_JSON"
done
set +f

STATE_FILE="$STATE_DIR/cursor-$CURSOR_PID.json"
STATE_TMP=$(mktemp "$STATE_DIR/.cursor-$CURSOR_PID.XXXXXX") || {
	echo "tmux-assistant-resurrect: failed to create temporary state file in $STATE_DIR" >&2
	exit 0
}
trap 'rm -f "$STATE_TMP"' EXIT
if ! (umask 077 && printf '%s' "$INPUT" | jq \
		--arg session_id "$SESSION_ID" \
		--arg tool "cursor" \
		--argjson pid "$CURSOR_PID" \
		--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson env "$ENV_JSON" \
		'. + {session_id: $session_id, tool: $tool, pid: $pid, timestamp: $timestamp, env: $env}' \
		>"$STATE_TMP" 2>/dev/null) || ! mv "$STATE_TMP" "$STATE_FILE"; then
	echo "tmux-assistant-resurrect: failed to write state file $STATE_FILE (permission denied?)" >&2
fi
