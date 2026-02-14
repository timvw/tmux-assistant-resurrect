#!/usr/bin/env bash
# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# Called automatically by tmux-resurrect after each save via:
#   set -g @resurrect-hook-post-save-all '/path/to/save-assistant-sessions.sh'

set -euo pipefail

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-/tmp/tmux-assistant-resurrect}"
RESURRECT_DIR="${HOME}/.tmux/resurrect"
OUTPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"

mkdir -p "$RESURRECT_DIR"

# Collect assistant sessions from all tmux panes
collect_sessions() {
	local sessions="[]"

	# Iterate over all tmux panes: session:window.pane, pane_pid, pane_current_path, pane_current_command
	while IFS=$'\t' read -r pane_target pane_pid pane_cwd pane_cmd; do
		local tool=""
		local session_id=""
		local child_pid=""

		# Find the actual assistant process (child of the shell in the pane)
		# pane_pid is the shell; we need its child processes
		# NOTE: pgrep -P is unreliable on macOS — use ps + awk instead
		local children
		children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v ppid="$pane_pid" '$2 == ppid {print $1}' || true)

		for cpid in $children; do
			local cmd_line
			cmd_line=$(ps -o args= -p "$cpid" 2>/dev/null || true)

			case "$cmd_line" in
			*claude*)
				tool="claude"
				child_pid="$cpid"
				# Claude: look up session from our hook-written state file
				session_id=$(get_claude_session "$pane_pid")
				break
				;;
			*opencode*)
				tool="opencode"
				child_pid="$cpid"
				# OpenCode: check process args first for -s flag
				# Handles both "opencode -s ses_XXX" and "opencode --session ses_XXX"
				session_id=$(echo "$cmd_line" | sed -n 's/.*-s \(ses_[A-Za-z0-9]*\).*/\1/p' || true)
				# Fallback: read from plugin state file (handles runtime session switches)
				if [ -z "$session_id" ]; then
					session_id=$(get_opencode_session "$cpid")
				fi
				break
				;;
			*codex*)
				tool="codex"
				child_pid="$cpid"
				# Codex: look up PID in session-tags.jsonl
				session_id=$(get_codex_session "$cpid")
				break
				;;
			esac
		done

		if [ -n "$tool" ] && [ -n "$session_id" ]; then
			local entry
			entry=$(jq -n \
				--arg pane "$pane_target" \
				--arg tool "$tool" \
				--arg sid "$session_id" \
				--arg cwd "$pane_cwd" \
				--arg pid "$child_pid" \
				'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid}')
			sessions=$(echo "$sessions" | jq --argjson entry "$entry" '. + [$entry]')
		fi
	done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}	#{pane_pid}	#{pane_current_path}	#{pane_current_command}")

	echo "$sessions"
}

# Get Claude session ID from our hook-written state file (keyed by shell PPID)
get_claude_session() {
	local shell_pid="$1"
	local state_file="$STATE_DIR/claude-${shell_pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
	fi
}

# Get OpenCode session ID from plugin state file (keyed by process PID)
get_opencode_session() {
	local pid="$1"

	# Method 1: plugin state file (most reliable — handles runtime session switches)
	local state_file="$STATE_DIR/opencode-${pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
		return
	fi

	# Method 2: not available without plugin — skip
	# The plugin state file is the reliable source for OpenCode sessions
	# without -s flag. Install the plugin via: just install-opencode-plugin
}

# Get Codex session ID from ~/.codex/session-tags.jsonl (PID lookup)
get_codex_session() {
	local pid="$1"
	local tags_file="${HOME}/.codex/session-tags.jsonl"
	if [ -f "$tags_file" ]; then
		# Find the most recent entry for this PID
		grep "\"pid\": *${pid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true
	fi
}

# Main
sessions=$(collect_sessions)
count=$(echo "$sessions" | jq 'length')

jq -n \
	--argjson sessions "$sessions" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{timestamp: $timestamp, sessions: $sessions}' >"$OUTPUT_FILE"

echo "tmux-assistant-resurrect: saved $count assistant session(s) to $OUTPUT_FILE"
