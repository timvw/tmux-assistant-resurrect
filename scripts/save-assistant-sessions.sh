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
LOG_FILE="${RESURRECT_DIR}/assistant-save.log"

mkdir -p "$RESURRECT_DIR"

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

# Detect which assistant tool a command line represents.
# Returns tool name or empty string.
detect_tool() {
	local cmd_line="$1"

	# Claude Code: native binary, path ends in /claude or is just "claude"
	# Exclude our own hook script (claude-session-track.sh)
	if echo "$cmd_line" | grep -qE '(^|/)claude( |$)'; then
		echo "claude"
		return
	fi

	# OpenCode: runs as node with /opencode in the args
	# Exclude LSP subprocesses (opencode run ...)
	if echo "$cmd_line" | grep -qE '(^|/)opencode( |$|-s |--session )' &&
		! echo "$cmd_line" | grep -qF 'opencode run '; then
		echo "opencode"
		return
	fi

	# Codex CLI: native binary, path ends in /codex or is just "codex"
	if echo "$cmd_line" | grep -qE '(^|/)codex( |$)'; then
		echo "codex"
		return
	fi
}

# Get Claude session ID from our hook-written state file (keyed by shell PPID)
get_claude_session() {
	local shell_pid="$1"
	local state_file="$STATE_DIR/claude-${shell_pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
	fi
}

# Get OpenCode session ID from process args or plugin state file
get_opencode_session() {
	local pid="$1"
	local cmd_line="$2"

	# Method 1: parse -s flag from process args (fast path)
	local sid
	sid=$(echo "$cmd_line" | sed -n 's/.*-s \(ses_[A-Za-z0-9_]*\).*/\1/p' || true)
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: parse --session flag from process args
	sid=$(echo "$cmd_line" | sed -n 's/.*--session \(ses_[A-Za-z0-9_]*\).*/\1/p' || true)
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 3: plugin state file (handles runtime session switches + no -s flag)
	local state_file="$STATE_DIR/opencode-${pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
		return
	fi

	# No session ID found — plugin not installed or session not yet tracked
}

# Get Codex session ID from ~/.codex/session-tags.jsonl (PID lookup)
get_codex_session() {
	local pid="$1"
	local tags_file="${HOME}/.codex/session-tags.jsonl"
	if [ -f "$tags_file" ]; then
		# Match exact PID (with comma or brace after the number to avoid partial matches)
		grep "\"pid\": *${pid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true
	fi
}

# Collect assistant sessions from all tmux panes
collect_sessions() {
	local sessions="[]"

	# Iterate over all tmux panes
	while IFS=$'\t' read -r pane_target pane_pid pane_cwd pane_cmd; do
		local tool=""
		local session_id=""
		local child_pid=""

		# Find child processes of the pane shell
		# NOTE: pgrep -P is unreliable on macOS — use ps + awk instead
		local children
		children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v ppid="$pane_pid" '$2 == ppid {print $1}' || true)

		for cpid in $children; do
			local cmd_line
			cmd_line=$(ps -o args= -p "$cpid" 2>/dev/null || true)
			[ -z "$cmd_line" ] && continue

			tool=$(detect_tool "$cmd_line")
			[ -z "$tool" ] && continue

			child_pid="$cpid"

			case "$tool" in
			claude)
				session_id=$(get_claude_session "$pane_pid")
				;;
			opencode)
				session_id=$(get_opencode_session "$cpid" "$cmd_line")
				;;
			codex)
				session_id=$(get_codex_session "$cpid")
				;;
			esac

			break
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
		elif [ -n "$tool" ]; then
			log "detected $tool in $pane_target (pid $child_pid) but could not extract session ID"
		fi
	done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}	#{pane_pid}	#{pane_current_path}	#{pane_current_command}")

	echo "$sessions"
}

# Main
sessions=$(collect_sessions)
count=$(echo "$sessions" | jq 'length')

jq -n \
	--argjson sessions "$sessions" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{timestamp: $timestamp, sessions: $sessions}' >"$OUTPUT_FILE"

log "saved $count assistant session(s) to $OUTPUT_FILE"
