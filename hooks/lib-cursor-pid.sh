#!/usr/bin/env bash
# Shared helper for Cursor hooks — find the Cursor Agent CLI ancestor PID.
# Cursor hooks may also run inside the desktop app, so unlike the Claude helper
# this deliberately has no $PPID fallback: a non-CLI hook must write no state.

find_cursor_pid() {
	local pid="$PPID"
	local max_depth=8
	while [ "$max_depth" -gt 0 ] && [ "$pid" -gt 1 ]; do
		local args first reglob=""
		args=$(ps -o args= -p "$pid" 2>/dev/null || true)
		case "$-" in
		*f*) ;;
		*) reglob=1 ;;
		esac
		set -f
		# shellcheck disable=SC2086 # deliberate split of ps's flattened argv
		set -- $args
		if [ -n "$reglob" ]; then set +f; fi
		first="${1:-}"
		first="${first##*/}"
		case "$first" in
		cursor-agent)
			printf '%s\n' "$pid"
			return 0
			;;
		agent)
			if [ "${2:-}" = "--use-system-ca" ]; then
				case "${3:-}" in
				*/index.js)
					printf '%s\n' "$pid"
					return 0
					;;
				esac
			fi
			;;
		node | nodejs | bun | deno | bash | sh | dash | ksh | zsh)
			[ "$#" -gt 1 ] || {
				pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
				case "$pid" in
				'' | *[!0-9]*) return 1 ;;
				esac
				max_depth=$((max_depth - 1))
				continue
			}
			case "${2##*/}" in
			cursor-agent)
				printf '%s\n' "$pid"
				return 0
				;;
			agent)
				if [ "${3:-}" = "--use-system-ca" ]; then
					case "${4:-}" in
					*/index.js)
						printf '%s\n' "$pid"
						return 0
						;;
					esac
				fi
				;;
			esac
			;;
		esac
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		case "$pid" in
		'' | *[!0-9]*) return 1 ;;
		esac
		max_depth=$((max_depth - 1))
	done
	return 1
}
