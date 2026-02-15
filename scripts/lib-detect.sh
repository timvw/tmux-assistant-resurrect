#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found

# --- detect_tool ---
# Match binary name with optional path prefix, standalone or with arguments.
# Handles: /path/to/claude, claude, claude --resume ..., opencode -s ..., etc.
# Excludes: opencode run ... (LSP subprocesses)
detect_tool() {
	local args="$1"
	case "$args" in
	claude | claude\ * | */claude | */claude\ *) echo "claude" ;;
	opencode | opencode\ * | */opencode | */opencode\ *)
		# Exclude LSP/language server subprocesses
		case "$args" in
		*"opencode run "*) ;;
		*) echo "opencode" ;;
		esac
		;;
	codex | codex\ * | */codex | */codex\ *) echo "codex" ;;
	esac
}

# --- pane_has_assistant ---
# Check if a pane has a running assistant anywhere in its process tree.
# Checks the pane PID itself (exec-replaced shells) AND walks the full
# descendant tree (handles wrappers like npx, env, direnv, bash -lc).
#
# Usage: pane_has_assistant <pane_shell_pid> [ps_snapshot]
# If ps_snapshot is not provided, takes a fresh snapshot.
# Returns 0 and prints the assistant PID if found, returns 1 otherwise.
pane_has_assistant() {
	local shell_pid="$1"
	local snapshot="${2:-$(ps -eo pid=,ppid=,args= 2>/dev/null)}"

	# Check the pane PID itself (handles exec-replaced shells, e.g. exec claude)
	local pane_args
	pane_args=$(echo "$snapshot" | awk -v pid="$shell_pid" '$1 == pid {print substr($0, index($0,$3)); exit}')
	if [ -n "$(detect_tool "$pane_args")" ]; then
		echo "$shell_pid"
		return 0
	fi

	# Walk the entire process tree under the pane shell.
	# Uses a single-pass awk that builds the descendant set as it goes.
	local found_pid
	found_pid=$(echo "$snapshot" | awk -v root="$shell_pid" '
		BEGIN { pids[root]=1 }
		{ if ($2 in pids) { pids[$1]=1; print $1, substr($0, index($0,$3)) } }
	' | while read -r cpid cargs; do
		if [ -n "$(detect_tool "$cargs")" ]; then
			echo "$cpid"
			break
		fi
	done)

	if [ -n "$found_pid" ]; then
		echo "$found_pid"
		return 0
	fi

	return 1
}

# --- posix_quote ---
# POSIX-safe single-quote escaping.  Wraps value in single quotes and
# replaces embedded single quotes with the sequence '"'"' which closes
# the single-quoted string, adds an escaped single quote in double quotes,
# and re-opens the single-quoted string.
#
# Safe for bash, zsh, sh, dash, and fish (fish accepts single-quoted strings).
posix_quote() {
	local val="$1"
	# Replace each ' with '"'"'
	val="${val//\'/\'\"\'\"\'}"
	printf "'%s'" "$val"
}
