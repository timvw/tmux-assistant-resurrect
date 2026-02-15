#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

RESURRECT_DIR="${HOME}/.tmux/resurrect"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg"
	echo "$msg" >>"$LOG_FILE"
}

if [ ! -f "$INPUT_FILE" ]; then
	log "no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read saved sessions
sessions=$(jq -r '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')

if [ "$count" -eq 0 ]; then
	log "no assistant sessions to restore"
	exit 0
fi

# Wait for panes to be fully initialized after resurrect restore
sleep 2

log "restoring $count assistant session(s)..."

# Use a temp file to avoid subshell variable scoping issues with pipes
tmpfile=$(mktemp)
echo "$sessions" | jq -c '.[]' >"$tmpfile"

restored=0
while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')

	# Check if the target pane's session exists
	tmux_session="${pane%%:*}"
	if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
		log "session '$tmux_session' does not exist, skipping pane $pane"
		continue
	fi

	# Check if the specific pane exists
	if ! tmux list-panes -t "$pane" >/dev/null 2>&1; then
		log "pane $pane does not exist, skipping"
		continue
	fi

	# Guard: skip if the pane already has a running assistant (e.g., if
	# @resurrect-processes launched it, or user restarted manually)
	pane_shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$pane_shell_pid" ]; then
		existing=$(ps -eo pid=,ppid=,args= 2>/dev/null | awk -v ppid="$pane_shell_pid" '$2 == ppid && (/claude/ || /opencode/ || /codex/) {print $1; exit}')
		if [ -n "$existing" ]; then
			log "pane $pane already has a running assistant (pid $existing), skipping"
			continue
		fi
	fi

	# Build the resume command for each tool
	resume_cmd=""
	case "$tool" in
	claude)
		resume_cmd="claude --resume '${session_id}'"
		;;
	opencode)
		resume_cmd="opencode -s '${session_id}'"
		;;
	codex)
		resume_cmd="codex resume '${session_id}'"
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac

	log "restoring $tool in $pane (session: $session_id)"

	# Build the full command: cd to cwd (if it exists) then resume.
	# Use printf %q to safely quote the cwd for the shell, handling single
	# quotes, spaces, and special characters.
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		safe_cwd=$(printf '%q' "$cwd")
		tmux send-keys -t "$pane" "cd ${safe_cwd} 2>/dev/null; ${resume_cmd}" Enter
	else
		tmux send-keys -t "$pane" "${resume_cmd}" Enter
	fi

	restored=$((restored + 1))

	# Stagger launches to avoid overwhelming the system
	sleep 1
done <"$tmpfile"

rm -f "$tmpfile"

log "restored $restored of $count assistant session(s)"
