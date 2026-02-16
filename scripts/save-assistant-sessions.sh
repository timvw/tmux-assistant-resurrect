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

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
RESURRECT_DIR="${HOME}/.tmux/resurrect"
OUTPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-save.log"

mkdir -p -m 0700 "$STATE_DIR"
mkdir -p "$RESURRECT_DIR"

# Rotate log: keep only the most recent 500 lines to prevent unbounded growth
# (continuum saves every 5 minutes, so this grows ~12 lines/hour).
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

# --- Session ID extraction ---

get_claude_session() {
	local claude_pid="$1"
	local args="$2"

	# Method 1: SessionStart hook state file (keyed by Claude PID).
	# The hook walks up the process tree to find the main 'claude' process,
	# so the state file is named claude-{claude_pid}.json.
	local state_file="$STATE_DIR/claude-${claude_pid}.json"
	if [ -f "$state_file" ]; then
		local sid
		sid=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2: --resume flag in process args (chicken-and-egg fallback)
	# After restore, claude is launched as `claude --resume <session_id>`.
	# Supports both `--resume <id>` and `--resume=<id>` forms.
	# If the SessionStart hook hasn't fired yet, the ID is still in the args.
	local sid
	sid=$(echo "$args" | sed -n "s/.*--resume[= ] *\([A-Za-z0-9_-]*\).*/\1/p")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

get_opencode_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"

	# Method 1: -s flag in process args (fastest)
	local sid
	sid=$(echo "$args" | sed -n 's/.*-s \(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: --session flag in process args (supports --session=<id> too)
	sid=$(echo "$args" | sed -n 's/.*--session[= ] *\(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 3: plugin state file (handles runtime session switches)
	local state_file="$STATE_DIR/opencode-${child_pid}.json"
	if [ -f "$state_file" ]; then
		sid=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 4: SQLite database (version-resilient fallback).
	# OpenCode stores sessions in ~/.local/share/opencode/opencode.db.
	# Query the most recently updated session matching the pane's cwd.
	# Uses python3 (available on Linux and macOS) since sqlite3 CLI
	# is not always installed (e.g. missing on Ubuntu minimal).
	local db_file="${HOME}/.local/share/opencode/opencode.db"
	if [ -n "$cwd" ] && [ -f "$db_file" ] && command -v python3 >/dev/null 2>&1; then
		sid=$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    cur = conn.cursor()
    cur.execute(
        'SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1',
        (sys.argv[2],))
    row = cur.fetchone()
    if row:
        print(row[0])
    conn.close()
except Exception:
    pass
" "$db_file" "$cwd" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

get_codex_session() {
	local child_pid="$1"
	local args="$2"

	# Method 1: session-tags.jsonl (written by Codex at runtime)
	local tags_file="${HOME}/.codex/session-tags.jsonl"
	if [ -f "$tags_file" ]; then
		local sid
		sid=$(grep "\"pid\": *${child_pid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2: resume arg in process args (chicken-and-egg fallback)
	# After restore, codex is launched as `codex resume <session_id>`.
	local sid
	sid=$(echo "$args" | sed -n "s/.*resume  *\([A-Za-z0-9_-]*\).*/\1/p")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

# --- Main ---

# Build a snapshot of all child processes once (avoid calling ps per pane)
PS_SNAPSHOT=$(ps -eo pid=,ppid=,args= 2>/dev/null)

# Temp file for collecting entries (avoids subshell scoping issues)
PARTS_FILE=$(mktemp)

emit_session() {
	local target="$1" tool="$2" cpid="$3" cargs="$4" cwd="$5"
	local session_id=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$cpid" "$cargs") ;;
	opencode) session_id=$(get_opencode_session "$cpid" "$cargs" "$cwd") ;;
	codex) session_id=$(get_codex_session "$cpid" "$cargs") ;;
	esac

	if [ -n "$session_id" ]; then
		jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg pid "$cpid" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid}' >>"$PARTS_FILE"
		return 0
	else
		log "detected $tool in $target (pid $cpid) but no session ID available"
		return 1
	fi
}

FOUND_FLAG=$(mktemp)
trap 'rm -f "$PARTS_FILE" "$FOUND_FLAG"' EXIT INT TERM

tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}" |
	while IFS='|' read -r target shell_pid cwd; do
		>"$FOUND_FLAG"

		# Check the pane PID itself (handles exec-replaced shells, e.g. exec claude)
		pane_args=$(echo "$PS_SNAPSHOT" | awk -v pid="$shell_pid" '$1 == pid {print substr($0, index($0,$3)); exit}')
		pane_tool=$(detect_tool "$pane_args")
		if [ -n "$pane_tool" ]; then
			if emit_session "$target" "$pane_tool" "$shell_pid" "$pane_args" "$cwd"; then
				echo 1 >"$FOUND_FLAG"
			fi
		fi

		# Walk the entire process tree under the pane shell to find assistants.
		# This handles wrappers like npx, env, direnv exec, bash -lc, etc.
		# We collect all descendant PIDs, then check each for an assistant match.
		# NOTE: single-pass awk assumes ps output is PID-ascending (parents before
		# children). See lib-detect.sh comment for rationale and limitations.
		if [ ! -s "$FOUND_FLAG" ]; then
			echo "$PS_SNAPSHOT" | awk -v root="$shell_pid" '
				BEGIN { pids[root]=1 }
				{ if ($2 in pids) { pids[$1]=1; print $1, $2, substr($0, index($0,$3)) } }
			' |
				while read -r cpid _ppid cargs; do
					tool=$(detect_tool "$cargs")
					[ -z "$tool" ] && continue

					emit_session "$target" "$tool" "$cpid" "$cargs" "$cwd" || true
					break # Only match the first assistant per pane
				done
		fi
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
