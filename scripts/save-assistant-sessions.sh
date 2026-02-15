#!/usr/bin/env bash
# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# Detection: inspects child processes of each tmux pane shell via ps.
# Session IDs: extracted from process args, hook state files, or tool-native files.
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

# --- Process-based assistant detection ---
#
# Detects assistants by matching binary names in the process args of
# direct children of tmux pane shells. This is infrastructure plumbing:
# we match the binary path, not screen content or heuristics.

detect_tool() {
	local args="$1"
	# Match binary name at end of a path component or standalone.
	# The patterns match: /path/to/claude, /path/to/opencode -s ..., etc.
	# Excludes: opencode run ... (LSP subprocesses)
	case "$args" in
	*/claude | */claude\ *) echo "claude" ;;
	*/opencode | */opencode\ *)
		# Exclude LSP/language server subprocesses
		case "$args" in
		*"opencode run "*) ;;
		*) echo "opencode" ;;
		esac
		;;
	*/codex | */codex\ *) echo "codex" ;;
	esac
}

# --- Session ID extraction ---

get_claude_session() {
	local shell_pid="$1"
	# Method 1: SessionStart hook state file (keyed by shell PID = PPID of claude)
	local state_file="$STATE_DIR/claude-${shell_pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
	fi
}

get_opencode_session() {
	local child_pid="$1"
	local args="$2"

	# Method 1: -s flag in process args (fastest)
	local sid
	sid=$(echo "$args" | sed -n 's/.*-s \(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: --session flag in process args
	sid=$(echo "$args" | sed -n 's/.*--session \(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 3: plugin state file (handles runtime session switches)
	local state_file="$STATE_DIR/opencode-${child_pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
	fi
}

get_codex_session() {
	local child_pid="$1"
	local tags_file="${HOME}/.codex/session-tags.jsonl"
	if [ -f "$tags_file" ]; then
		grep "\"pid\": *${child_pid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true
	fi
}

# --- Main ---

# Build a snapshot of all child processes once (avoid calling ps per pane)
PS_SNAPSHOT=$(ps -eo pid=,ppid=,args= 2>/dev/null)

# Temp file for collecting entries (avoids subshell scoping issues)
PARTS_FILE=$(mktemp)
trap 'rm -f "$PARTS_FILE"' EXIT

tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}" |
	while IFS='|' read -r target shell_pid cwd; do
		# Find direct children of the pane shell
		echo "$PS_SNAPSHOT" | awk -v ppid="$shell_pid" '$2 == ppid {print $1, $2, substr($0, index($0,$3))}' |
			while read -r cpid _ppid cargs; do
				tool=$(detect_tool "$cargs")
				[ -z "$tool" ] && continue

				session_id=""
				case "$tool" in
				claude) session_id=$(get_claude_session "$shell_pid") ;;
				opencode) session_id=$(get_opencode_session "$cpid" "$cargs") ;;
				codex) session_id=$(get_codex_session "$cpid") ;;
				esac

				if [ -n "$session_id" ]; then
					jq -n \
						--arg pane "$target" \
						--arg tool "$tool" \
						--arg sid "$session_id" \
						--arg cwd "$cwd" \
						--arg pid "$cpid" \
						'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid}' >>"$PARTS_FILE"
				else
					log "detected $tool in $target (pid $cpid) but no session ID available"
				fi

				break # Only match the first assistant per pane
			done
	done

# Assemble final JSON
if [ -s "$PARTS_FILE" ]; then
	sessions=$(jq -s '.' "$PARTS_FILE")
else
	sessions="[]"
fi

count=$(echo "$sessions" | jq 'length')

jq -n \
	--argjson sessions "$sessions" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{timestamp: $timestamp, sessions: $sessions}' >"$OUTPUT_FILE"

log "saved $count assistant session(s) to $OUTPUT_FILE"
