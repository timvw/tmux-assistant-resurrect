#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

RESURRECT_DIR="${HOME}/.tmux/resurrect"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

# Rotate log: keep only the most recent 500 lines
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
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
trap 'rm -f "$tmpfile"' EXIT INT TERM
echo "$sessions" | jq -c '.[]' >"$tmpfile"

restored=0
while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')
	cli_args=$(echo "$entry" | jq -r '.cli_args // empty')
	env_json=$(echo "$entry" | jq -c '.env // {}')

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

	# Guard 1: skip if the pane is not running a shell.
	# After tmux-resurrect restore, panes should be running a shell (bash, zsh,
	# etc.). If something else is running (e.g., the user manually started vim,
	# or @resurrect-processes restored a non-assistant program), injecting
	# send-keys would feed commands into the wrong program.
	pane_cmd=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || true)
	# Strip leading '-' from login shells (e.g., -bash -> bash, -zsh -> zsh)
	pane_cmd="${pane_cmd#-}"
	case "$pane_cmd" in
	bash | zsh | fish | sh | dash | ksh | tcsh | csh | nu) ;;
	*)
		log "pane $pane is running '$pane_cmd' (not a shell), skipping"
		continue
		;;
	esac

	# Guard 2: skip if the pane already has a running assistant (e.g., if
	# @resurrect-processes launched it, or user restarted manually).
	# Uses the same full tree walk + detect_tool() as the save script to
	# catch exec-replaced shells, wrappers (npx, env, direnv), and deep
	# process chains.
	pane_shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$pane_shell_pid" ]; then
		existing=$(pane_has_assistant "$pane_shell_pid" || true)
		if [ -n "$existing" ]; then
			log "pane $pane already has a running assistant (pid $existing), skipping"
			continue
		fi
	fi

	# Build env prefix: only restore user-configured vars from
	# @assistant-resurrect-capture-env. Exclude built-in vars (tmux_pane, shell)
	# which would be stale or already present in the shell environment.
	env_prefix=""
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
		for var in $capture_env; do
			val=$(echo "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			if [ -n "$val" ]; then
				env_prefix="${env_prefix}${var}=$(posix_quote "$val") "
			fi
		done
	fi

	# Build the resume command for each tool.
	# Apply posix_quote to session_id defensively — IDs are alphanumeric in
	# practice, but a corrupt/tampered sidecar JSON could inject shell commands.
	safe_sid=$(posix_quote "$session_id")
	resume_cmd=""
	case "$tool" in
	claude)
		if [ -n "$cli_args" ]; then
			resume_cmd="claude ${cli_args} --resume ${safe_sid}"
		else
			resume_cmd="claude --resume ${safe_sid}"
		fi
		;;
	opencode)
		if [ -n "$cli_args" ]; then
			resume_cmd="opencode ${cli_args} -s ${safe_sid}"
		else
			resume_cmd="opencode -s ${safe_sid}"
		fi
		;;
	codex)
		if [ -n "$cli_args" ]; then
			resume_cmd="codex ${cli_args} resume ${safe_sid}"
		else
			resume_cmd="codex resume ${safe_sid}"
		fi
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac

	# Prepend env vars if present
	if [ -n "$env_prefix" ]; then
		resume_cmd="${env_prefix}${resume_cmd}"
	fi

	log "restoring $tool in $pane (session: $session_id, cmd: $resume_cmd)"

	# Clear the pane before launching: tmux-resurrect may have restored old
	# pane contents (captured terminal text from the previous session). Without
	# clearing, TUI tools like Claude show stale output above the new instance.
	# Uses tmux clear-history to wipe scrollback, then sends 'clear' to reset
	# the visible area.
	tmux send-keys -t "$pane" "clear" Enter
	tmux clear-history -t "$pane"
	sleep 0.3

	# Build the full command: cd to cwd (if it exists) then resume.
	# Use POSIX single-quote escaping (safe for bash, zsh, sh, dash, fish).
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		safe_cwd=$(posix_quote "$cwd")
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
