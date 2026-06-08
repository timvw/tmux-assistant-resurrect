#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found
#   resurrect_data_dir           — prints tmux-resurrect's save directory

# --- detect_tool ---
# Match binary name with optional path prefix, standalone or with arguments.
# Handles: /path/to/claude, claude, claude --resume ..., opencode -s ...,
#          codex resume ..., pi --session ..., etc.
# Excludes: opencode run ... (LSP subprocesses)
#
# Limitation: patterns match any command line containing /claude, /opencode,
# /codex, or /pi as a path component. An unrelated binary with the same name
# (e.g., a LaTeX tool named "codex") would be falsely detected. In practice this is rare
# inside tmux panes, but worth noting. Future: could verify identity via
# --version or known subcommands if false positives become an issue.
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
	pi | pi\ * | */pi | */pi\ *) echo "pi" ;;
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
	#
	# Assumption: ps output is ordered by ascending PID, so parents appear
	# before children. POSIX doesn't guarantee this, but it holds on Linux
	# (procfs enumeration) and macOS (libproc). If a child PID appeared before
	# its parent, it would be missed. A multi-pass approach would be more
	# robust but slower; in practice, single-pass has been reliable.
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

# --- resurrect_data_dir ---
# Print the directory tmux-resurrect saves into, resolved the SAME way resurrect
# resolves it itself (scripts/helpers.sh:resurrect_dir). Our sidecar files
# (assistant-sessions.json, *.log) and the pane_contents.tar.gz we rewrite must
# live next to resurrect's own saves, so this has to track resurrect's logic
# rather than assume a fixed location.
#
# Resolution order:
#   1. $TMUX_RESURRECT_DIR        — explicit override (tests / unusual setups)
#   2. @resurrect-dir tmux option — when the user set one
#   3. ~/.tmux/resurrect          — when that directory already exists (legacy default)
#   4. ${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect — modern (XDG) default
#
# Why this matters — do NOT hardcode ~/.tmux/resurrect: on an XDG install that
# directory does not exist, so resurrect saves under ~/.local/share. Writing our
# files to ~/.tmux/resurrect anyway would not only split them away from
# resurrect's real saves, it would `mkdir` that directory — and resurrect's own
# dir-exists check (step 3) would then flip the user's save location to it on the
# next run, silently migrating their data and orphaning prior saves.
#
# Mirrors resurrect's expansion of ~, $HOME and $HOSTNAME inside @resurrect-dir.
resurrect_data_dir() {
	if [ -n "${TMUX_RESURRECT_DIR:-}" ]; then
		echo "$TMUX_RESURRECT_DIR"
		return
	fi

	local dir
	dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
	if [ -z "$dir" ]; then
		if [ -d "$HOME/.tmux/resurrect" ]; then
			dir="$HOME/.tmux/resurrect"
		else
			dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
		fi
	fi

	local host
	host=$(hostname 2>/dev/null || true)
	echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}
