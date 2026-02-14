#!/usr/bin/env bash
# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# ZFC compliant: agent detection is delegated to pane-patrol (LLM-based).
# This script only handles infrastructure plumbing: process inspection for
# session IDs, state file I/O, and tmux interaction.
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

# --- Agent detection (ZFC: delegated to pane-patrol) ---

# Scan all panes using pane-patrol. Returns JSON array of verdicts.
# Each verdict has: target, agent, command, session, window, pane
scan_panes() {
	if ! command -v pane-patrol &>/dev/null; then
		log "ERROR: pane-patrol not found in PATH. Install via: brew install timvw/tap/pane-patrol"
		echo "[]"
		return
	fi

	local verdicts
	verdicts=$(pane-patrol scan 2>/dev/null || true)

	if [ -z "$verdicts" ]; then
		log "pane-patrol scan returned empty output"
		echo "[]"
		return
	fi

	echo "$verdicts"
}

# Normalize agent names from pane-patrol's LLM output to canonical tool names.
# The LLM may return "Claude Code", "claude-code", "OpenCode", etc.
# This is infrastructure plumbing (string normalization), not cognitive interpretation.
normalize_agent() {
	local agent="$1"
	local lower
	lower=$(echo "$agent" | tr '[:upper:]' '[:lower:]' | tr -d ' -')

	case "$lower" in
	*claudecode* | *claude*) echo "claude" ;;
	*opencode*) echo "opencode" ;;
	*codex*) echo "codex" ;;
	*) echo "" ;; # Unknown agent — not one we can extract session IDs for
	esac
}

# --- Session ID extraction (infrastructure plumbing) ---

# Get Claude session ID from our hook-written state file (keyed by shell PPID)
get_claude_session() {
	local pane_pid="$1"
	local state_file="$STATE_DIR/claude-${pane_pid}.json"
	if [ -f "$state_file" ]; then
		jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
	fi
}

# Get OpenCode session ID from process args or plugin state file
get_opencode_session() {
	local pane_pid="$1"

	# Find the opencode child process of the pane shell
	local children
	children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v ppid="$pane_pid" '$2 == ppid {print $1}' || true)

	for cpid in $children; do
		local cmd_line
		cmd_line=$(ps -o args= -p "$cpid" 2>/dev/null || true)

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

		# Method 3: plugin state file (handles runtime session switches)
		local state_file="$STATE_DIR/opencode-${cpid}.json"
		if [ -f "$state_file" ]; then
			jq -r '.session_id // empty' "$state_file" 2>/dev/null || true
			return
		fi
	done
}

# Get Codex session ID from ~/.codex/session-tags.jsonl (PID lookup)
get_codex_session() {
	local pane_pid="$1"
	local tags_file="${HOME}/.codex/session-tags.jsonl"

	if [ ! -f "$tags_file" ]; then
		return
	fi

	# Find child processes and look up their PIDs in session-tags
	local children
	children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v ppid="$pane_pid" '$2 == ppid {print $1}' || true)

	for cpid in $children; do
		local sid
		sid=$(grep "\"pid\": *${cpid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	done
}

# --- Main: collect and save ---

# Map pane target to its shell PID (needed for session ID extraction)
declare -A pane_pids
while IFS=$'\t' read -r target pid; do
	pane_pids["$target"]="$pid"
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}	#{pane_pid}")

# Map pane target to its working directory
declare -A pane_cwds
while IFS=$'\t' read -r target cwd; do
	pane_cwds["$target"]="$cwd"
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}	#{pane_current_path}")

# Scan panes via pane-patrol (ZFC: LLM classifies agents)
log "scanning panes via pane-patrol..."
verdicts=$(scan_panes)

# Process verdicts: extract session IDs for detected agents
sessions="[]"
agent_count=0

echo "$verdicts" | jq -c '.[]' 2>/dev/null | while read -r verdict; do
	target=$(echo "$verdict" | jq -r '.target')
	agent=$(echo "$verdict" | jq -r '.agent')

	# Normalize the LLM's agent name to our canonical tool names
	tool=$(normalize_agent "$agent")
	[ -z "$tool" ] && continue

	# Get the pane's shell PID for session ID extraction
	pane_pid="${pane_pids[$target]:-}"
	if [ -z "$pane_pid" ]; then
		log "no PID found for pane $target, skipping"
		continue
	fi

	cwd="${pane_cwds[$target]:-}"

	# Extract the session ID using tool-specific plumbing
	session_id=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$pane_pid") ;;
	opencode) session_id=$(get_opencode_session "$pane_pid") ;;
	codex) session_id=$(get_codex_session "$pane_pid") ;;
	esac

	if [ -n "$session_id" ]; then
		entry=$(jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg agent "$agent" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, agent_raw: $agent}')
		# Append to temp file to avoid subshell scoping
		echo "$entry" >>"${OUTPUT_FILE}.parts"
		agent_count=$((agent_count + 1))
	else
		log "detected $tool ($agent) in $target but could not extract session ID"
	fi
done

# Assemble final JSON from parts
if [ -f "${OUTPUT_FILE}.parts" ]; then
	sessions=$(jq -s '.' "${OUTPUT_FILE}.parts")
	rm -f "${OUTPUT_FILE}.parts"
else
	sessions="[]"
fi

count=$(echo "$sessions" | jq 'length')

jq -n \
	--argjson sessions "$sessions" \
	--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{timestamp: $timestamp, sessions: $sessions}' >"$OUTPUT_FILE"

log "saved $count assistant session(s) to $OUTPUT_FILE"
