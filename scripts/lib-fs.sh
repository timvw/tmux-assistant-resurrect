#!/usr/bin/env bash
# Shared filesystem helpers for updating a user-owned config file in place.
#
# A dotfile manager commonly symlinks the files this plugin edits
# (~/.claude/settings.json, ~/.cursor/hooks.json, ~/.tmux.conf). Writing them
# with `mktemp` + `mv` onto the path the user gave replaces the link itself and
# silently detaches the file from the repo tracking it, so every writer resolves
# the chain first and publishes beside the resolved target instead.
#
# Sourced by tmux-assistant-resurrect.tmux and by the justfile recipes; both
# already depend on scripts/ being present.

# Walk a symlink chain and print the final target. Bounded, because a cycle
# would otherwise spin forever. Relative links resolve against the directory
# holding the link, and `..` is left in place: normalising it lexically would
# change which file a chain through a symlinked directory refers to.
#
# Exit status: 0 and prints the resolved path; 1 if a readlink failed; 2 if the
# chain is too deep or cyclic. Callers distinguish the two so their message can
# say which.
#
# Known limitation: a target name ending in a newline reads back identically to
# one without it, because BSD readlink appends a newline of its own, so such a
# link resolves to the shorter name.
resolve_symlink_target() {
	local target="$1" link link_depth=0
	while [ -L "$target" ] && [ "$link_depth" -lt 16 ]; do
		link=$(readlink "$target") || return 1
		case "$link" in
			/*) target="$link" ;;
			*) target="$(dirname "$target")/$link" ;;
		esac
		link_depth=$((link_depth + 1))
	done
	if [ -L "$target" ]; then
		return 2
	fi
	printf '%s' "$target"
}

# Print a file's permission bits as octal digits, or return 1.
#
# BSD stat's %p includes the file type plus all permission bits; keep its final
# four octal digits. The literal "mode:" prefix makes GNU stat -f output fail
# the octal guard below, so the GNU -c form is retried. GNU's own -c '%a' may
# return three digits rather than four; chmod accepts either.
file_mode_of() {
	local path="$1" mode
	mode=$(stat -f 'mode:%p' "$path" 2>/dev/null || true)
	case "$mode" in
		mode:*) mode=${mode#mode:} ;;
		*) mode="" ;;
	esac
	case "$mode" in
		'' | *[!0-7]*) mode="" ;;
		*)
			if [ "${#mode}" -ge 4 ]; then
				mode=${mode#"${mode%????}"}
			else
				mode=""
			fi
			;;
	esac
	case "$mode" in
		'' | *[!0-7]*) mode=$(stat -c '%a' "$path" 2>/dev/null || true) ;;
	esac
	case "$mode" in
		'' | *[!0-7]*) return 1 ;;
	esac
	printf '%s' "$mode"
}
