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
	#
	# Limitation: this is NOT PID-specific. If two OpenCode instances run in
	# the same directory (both without -s flags and without plugin state files),
	# both panes get the most recently updated session ID — one of them will be
	# wrong. To avoid this, launch with explicit session IDs: opencode -s <id>.
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

# --- CLI args extraction ---

# Extract CLI args from a process's full command line, stripping the binary
# name/path and tool-specific session/resume arguments.
#
# Usage: extract_cli_args <tool> <full_args_from_ps>
# Returns: the remaining flags/args as a single whitespace-normalized string.
#
# Per-tool stripping:
#   claude:   --resume <id>, --resume=<id>
#   opencode: -s <id>, --session <id>, --session=<id>
#   codex:    resume <id> (positional subcommand)
extract_cli_args() {
	local tool="$1" raw_args="$2"

	# Strip binary name/path: remove first token (which is the binary or /path/to/binary).
	local args="${raw_args#* }"
	# If there was no space (bare binary name), args equals raw_args — set to empty
	if [ "$args" = "$raw_args" ]; then
		echo ""
		return
	fi

	# Node.js processes (claude, codex) may show a second token that is the
	# script path, e.g. `claude /usr/local/bin/claude --resume ...`.
	# Strip any leading token that is a path ending in the tool binary name.
	local first_arg="${args%% *}"
	case "$first_arg" in
	*/"$tool")
		args="${args#"$first_arg"}"
		args="${args# }"
		;;
	esac

	# Strip tool-specific session/resume args.
	# Patterns use [= ] *  to handle both --flag=val and --flag val forms,
	# and to tolerate multiple spaces between flag and value.
	case "$tool" in
	claude)
		# --resume <id> or --resume=<id>
		args=$(echo "$args" | sed -E 's/--resume[= ] *[^ ]*//')
		;;
	opencode)
		# -s <id>, --session <id>, --session=<id>
		args=$(echo "$args" | sed -E 's/--session[= ] *[^ ]*//; s/-s  *[^ ]*//')
		;;
	codex)
		# resume <id> (positional)
		args=$(echo "$args" | sed -E 's/resume  *[^ ]*//')
		;;
	esac

	# Normalize whitespace: collapse multiple spaces, trim leading/trailing
	echo "$args" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

# --- Main ---

main() {
	# Build a snapshot of all child processes once (avoid calling ps per pane)
	PS_SNAPSHOT=$(ps -eo pid=,ppid=,args= 2>/dev/null)

	# Temp file for collecting entries (avoids subshell scoping issues)
	PARTS_FILE=$(mktemp)

	FOUND_FLAG=$(mktemp)
	trap 'rm -f "$PARTS_FILE" "$FOUND_FLAG"' EXIT INT TERM

	# Delimiter: pipe (|) separates fields. tmux 3.4+ converts control characters
	# (like \x1f) to octal escapes in -F output, so we use a printable delimiter.
	# Limitation: directory names containing | will break parsing. While | is a
	# valid path character on Linux and macOS, it is extremely rare in practice.
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
	local sessions count
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

	# Strip captured pane contents for assistant panes so tmux-resurrect
	# won't restore stale TUI output that the post-restore hook would
	# immediately replace. Non-assistant pane contents are preserved.
	if [ "$count" -gt 0 ]; then
		strip_assistant_pane_contents
	fi
}

# Remove assistant pane entries from tmux-resurrect's pane_contents.tar.gz.
# tmux-resurrect stores captured pane text in an archive with entries like:
#   ./pane_contents/pane-{session_name}:{window_index}.{pane_index}
# Our saved JSON uses the same "{session}:{window}.{pane}" target format,
# so the mapping is direct.
#
# Upstream assumption: tmux-resurrect archive layout uses the naming convention
# described above. Verified against tmux-resurrect helpers.sh:pane_contents_file().
strip_assistant_pane_contents() {
	local archive="$RESURRECT_DIR/pane_contents.tar.gz"
	[ -f "$archive" ] || return 0

	# Collect pane targets from the sessions we just saved
	local panes
	panes=$(jq -r '.sessions[].pane' "$OUTPUT_FILE" 2>/dev/null) || return 0
	[ -z "$panes" ] && return 0

	local tmpdir
	tmpdir=$(mktemp -d) || return 0

	# Extract, remove assistant pane files, re-archive.
	# If any step fails, log a warning and leave the archive untouched.
	if ! (gzip -d <"$archive" | tar xf - -C "$tmpdir") 2>/dev/null; then
		log "warning: failed to extract pane_contents archive, skipping content stripping"
		rm -rf "$tmpdir"
		return 0
	fi

	local removed=0
	while IFS= read -r pane_target; do
		local content_file="$tmpdir/pane_contents/pane-${pane_target}"
		if [ -f "$content_file" ]; then
			rm -f "$content_file"
			removed=$((removed + 1))
		fi
	done <<<"$panes"

	if [ "$removed" -gt 0 ]; then
		if tar cf - -C "$tmpdir" ./pane_contents/ | gzip >"${archive}.tmp" 2>/dev/null; then
			mv "${archive}.tmp" "$archive"
			log "stripped pane contents for $removed assistant pane(s)"
		else
			log "warning: failed to repack pane_contents archive"
			rm -f "${archive}.tmp"
		fi
	fi

	rm -rf "$tmpdir"
}

# Internal helper — called from main(). Requires PARTS_FILE to be set.
emit_session() {
	local target="$1" tool="$2" cpid="$3" cargs="$4" cwd="$5"
	local session_id=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$cpid" "$cargs") ;;
	opencode) session_id=$(get_opencode_session "$cpid" "$cargs" "$cwd") ;;
	codex) session_id=$(get_codex_session "$cpid" "$cargs") ;;
	esac

	if [ -n "$session_id" ]; then
		# Extract CLI args (flags without binary name and session/resume args)
		local cli_args
		cli_args=$(extract_cli_args "$tool" "$cargs")

		# Read enriched fields from state file (if available)
		local state_file="" model="" env_json="null"
		case "$tool" in
		claude) state_file="$STATE_DIR/claude-${cpid}.json" ;;
		opencode) state_file="$STATE_DIR/opencode-${cpid}.json" ;;
		esac

		if [ -n "$state_file" ] && [ -f "$state_file" ]; then
			model=$(jq -r '.model // empty' "$state_file" 2>/dev/null || true)
			env_json=$(jq '.env // null' "$state_file" 2>/dev/null || echo "null")
		fi

		# Fallback: parse --model from CLI args if not in state file
		if [ -z "$model" ]; then
			model=$(echo "$cargs" | sed -n 's/.*--model[= ] *\([^ ]*\).*/\1/p')
		fi

		jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg pid "$cpid" \
			--arg model "$model" \
			--arg cli_args "$cli_args" \
			--argjson env "${env_json:-null}" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid, model: $model, cli_args: $cli_args, env: $env}' >>"$PARTS_FILE"
		return 0
	else
		log "detected $tool in $target (pid $cpid) but no session ID available"
		return 1
	fi
}

# Allow sourcing this script without executing main (for unit tests).
# When sourced, only functions and variables are defined.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
