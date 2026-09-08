#!/usr/bin/env bash
# Shared helper for Claude hooks — finds the main Claude process PID.
# Sourced by claude-session-track.sh and claude-session-cleanup.sh.
#
# Claude may spawn hooks via an intermediate process (e.g., sh -c 'bash hook.sh'),
# so $PPID is not necessarily the main Claude process. This walks up the process
# tree to find the ancestor whose command is 'claude'.

# Walk up the process tree from $PPID to find the main Claude process.
# On some systems $PPID IS the Claude PID; on others there's an intermediate
# shell (sh -c) between Claude and the hook.
find_claude_pid() {
	local pid="$PPID"
	local max_depth=5
	while [ "$max_depth" -gt 0 ] && [ "$pid" -gt 1 ]; do
		local cmd
		cmd=$(ps -o comm= -p "$pid" 2>/dev/null || true)
		case "$cmd" in
		claude | */claude)
			echo "$pid"
			return
			;;
		esac
		# Native-install Claude exec'd by its versioned path
		# (~/.local/share/claude/versions/<version>): comm is then the version
		# number, which is what Linux reports for the exec'd file, and only
		# argv[0] still names claude.
		local args
		args=$(ps -o args= -p "$pid" 2>/dev/null || true)
		case "${args%% *}" in
		*/claude/versions/[0-9]*)
			echo "$pid"
			return
			;;
		esac
		# Move to parent
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		max_depth=$((max_depth - 1))
	done
	# Fallback: use $PPID if we couldn't find 'claude' in the ancestry
	echo "$PPID"
}
