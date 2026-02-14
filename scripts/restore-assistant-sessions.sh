#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

RESURRECT_DIR="${HOME}/.tmux/resurrect"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"

if [ ! -f "$INPUT_FILE" ]; then
	echo "tmux-assistant-resurrect: no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read saved sessions
sessions=$(jq -r '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')

if [ "$count" -eq 0 ]; then
	echo "tmux-assistant-resurrect: no assistant sessions to restore"
	exit 0
fi

# Wait briefly for panes to be fully initialized after resurrect restore
sleep 2

# Restore each assistant
restored=0
echo "$sessions" | jq -c '.[]' | while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')

	# Check if the target pane exists
	if ! tmux has-session -t "${pane%%.*}" 2>/dev/null; then
		echo "tmux-assistant-resurrect: pane $pane no longer exists, skipping"
		continue
	fi

	# Build the resume command for each tool
	resume_cmd=""
	case "$tool" in
	claude)
		resume_cmd="claude --resume ${session_id}"
		;;
	opencode)
		resume_cmd="opencode -s ${session_id}"
		;;
	codex)
		resume_cmd="codex resume ${session_id}"
		;;
	*)
		echo "tmux-assistant-resurrect: unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac

	# First cd to the working directory, then launch the assistant
	echo "tmux-assistant-resurrect: restoring $tool in $pane (session: $session_id)"
	tmux send-keys -t "$pane" "cd '${cwd}' && ${resume_cmd}" Enter

	restored=$((restored + 1))
done

echo "tmux-assistant-resurrect: restored $restored of $count assistant session(s)"
