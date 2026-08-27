#!/usr/bin/env bash
# shellcheck disable=SC2034  # per-tool variable families accessed via ${!var} dynamic expansion
# The tmux server may have been started with a limited PATH (e.g. via a
# systemd user service with a whitelisted runtime environment). That PATH
# is inherited by every hook this script runs in, so utilities like
# python3 — needed by Python-based session lookup methods (Codex + pi) —
# can be missing even though they are installed and work fine from an
# interactive shell. Augment PATH with common system locations so the
# hook context sees what the rest of the system sees.
if ! command -v python3 >/dev/null 2>&1; then
	for _dir in /run/current-system/sw/bin /opt/homebrew/bin /usr/local/bin /usr/bin; do
		if [ -x "$_dir/python3" ]; then
			PATH="$_dir:$PATH"
			break
		fi
	done
	unset _dir
fi

# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# Detection: inspects child processes of each tmux pane shell via ps.
# Session IDs: extracted from process args, hook state files, or tool-native files.
#
# Called automatically by tmux-resurrect after each save via:
#   set -g @resurrect-hook-post-save-all '/path/to/save-assistant-sessions.sh'

set -euo pipefail

# Sidecars can contain captured environment values and session identifiers.
# Keep every file this executable creates private, independently of the user's
# interactive-shell umask. Do not alter the caller's umask when tests source us.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	umask 077
fi

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

# Directory of helper Python programs. These live as standalone files (rather
# than inline heredocs) so python3 receives them via argv instead of a shell
# heredoc pipe. On bash >= 5.1 a heredoc/here-string is written to a pipe
# *before* the reader is exec'd; if the pipe buffer cannot grow (e.g. macOS
# under pipe-KVA pressure) that pre-fork write blocks forever, hanging the save
# hook. Delivering programs via argv sidesteps that failure mode entirely.
PY_DIR="$SCRIPT_DIR/py"

# Shared with the SessionStart/SessionEnd hooks, which write and delete these
# files from the assistant's process environment rather than the tmux server's.
STATE_DIR="$(assistant_state_dir)"

# Panes where a tool was detected but neither a session ID nor an authorized
# relaunch command could be resolved. Such a pane is dropped from the sidecar;
# without this the save reports plain success and the loss is easy to miss.
UNRESOLVED_PANES=0
# Follow tmux-resurrect's own save-dir resolution (see resurrect_data_dir in
# lib-detect.sh) instead of hardcoding ~/.tmux/resurrect, so our sidecar lands
# next to resurrect's saves on both legacy and XDG installs.
RESURRECT_DIR="$(resurrect_data_dir)"
OUTPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-save.log"
LOG_ENABLED=0
CAPTURE_ENV=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
RELAUNCH_ENABLED=$(tmux show-option -gqv @assistant-resurrect-relaunch 2>/dev/null || true)
RELAUNCH_ENABLED="${RELAUNCH_ENABLED:-on}"
RELAUNCH_LEDGER_FILE="${RESURRECT_DIR}/assistant-relaunch-candidates.json"
RELAUNCH_LEDGER_TMP=""

# Watchdog deadline (seconds). Defense-in-depth: even without heredoc pipes, a
# subprocess (python3 on a locked sqlite, a stat on a slow filesystem, a wedged
# tmux call) could still hang the save hook. The watchdog guarantees bounded
# completion and prevents blocked processes from accumulating. Configurable via
# the tmux option or the env var; set to 0 to disable. Default: 60s (continuum
# saves every 5 min, and a normal save finishes in a few seconds even at scale).
SAVE_TIMEOUT=$(tmux show-option -gqv @assistant-resurrect-save-timeout 2>/dev/null || true)
SAVE_TIMEOUT="${SAVE_TIMEOUT:-${ASSISTANT_RESURRECT_SAVE_TIMEOUT:-60}}"
case "$SAVE_TIMEOUT" in
'' | *[!0-9]*) SAVE_TIMEOUT=60 ;;
esac

# Shared with the SessionStart hook that writes what this reads; see the function.
ensure_assistant_state_dir "$STATE_DIR"
mkdir -p "$RESURRECT_DIR"

# Move an existing log aside without following it, then create the replacement
# atomically under noclobber and retain its descriptor. Later path replacement
# cannot redirect writes. The moved file is rechecked before it is read so a
# raced symlink is never used as rotation input.
_log_previous=""
_log_previous_copied=0
if [ -e "$LOG_FILE" ] || [ -L "$LOG_FILE" ]; then
	if [ -L "$LOG_FILE" ]; then
		printf '%s\n' "tmux-assistant-resurrect: refusing symlinked save log: $LOG_FILE" >&2
	elif [ ! -f "$LOG_FILE" ]; then
		printf '%s\n' "tmux-assistant-resurrect: refusing non-regular save log: $LOG_FILE" >&2
	else
		_log_previous=$(mktemp "${LOG_FILE}.rotate.XXXXXX" 2>/dev/null || true)
		if [ -z "$_log_previous" ] || ! mv "$LOG_FILE" "$_log_previous" 2>/dev/null; then
			printf '%s\n' "tmux-assistant-resurrect: cannot rotate save log, disabling file logging: $LOG_FILE" >&2
			[ -z "$_log_previous" ] || rm -f "$_log_previous"
			_log_previous=""
		fi
	fi
fi

if { [ ! -e "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ]; } &&
	{ [ -z "$_log_previous" ] || { [ -f "$_log_previous" ] && [ ! -L "$_log_previous" ]; }; }; then
	_log_had_noclobber=0
	case "$-" in *C*) _log_had_noclobber=1 ;; esac
	_log_old_umask=$(umask)
	umask 077
	set -C
	if exec 9>"$LOG_FILE"; then
		LOG_ENABLED=1
	fi
	[ "$_log_had_noclobber" -eq 1 ] || set +C
	umask "$_log_old_umask"
	if [ "$LOG_ENABLED" -eq 1 ] && [ -n "$_log_previous" ]; then
		if tail -n 500 "$_log_previous" >&9 2>/dev/null; then
			_log_previous_copied=1
		fi
	fi
fi

if [ -n "$_log_previous" ]; then
	if [ "$LOG_ENABLED" -eq 1 ] && [ "$_log_previous_copied" -eq 1 ]; then
		rm -f "$_log_previous"
	else
		printf '%s\n' "tmux-assistant-resurrect: previous save log retained at $_log_previous" >&2
	fi
fi
if [ "$LOG_ENABLED" -ne 1 ] && [ ! -e "$LOG_FILE" ]; then
	printf '%s\n' "tmux-assistant-resurrect: cannot securely open save log, disabling file logging: $LOG_FILE" >&2
fi
unset _log_previous _log_previous_copied _log_had_noclobber _log_old_umask

log() {
	local msg
	msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	msg="${msg//$'\r'/\\r}"
	msg="${msg//$'\n'/\\n}"
	msg="${msg//$'\033'/\\e}"
	printf '%s\n' "$msg" >&2
	if [ "$LOG_ENABLED" -eq 1 ]; then
		if ! printf '%s\n' "$msg" >&9 2>/dev/null; then
			LOG_ENABLED=0
			printf '%s\n' "tmux-assistant-resurrect: cannot write save log, disabling file logging: $LOG_FILE" >&2
		fi
	fi
}

# Move state files left in any pre-$HOME default into the current state dir.
#
# Upgrades happen under a live tmux server: assistants that were already running
# fired their SessionStart hook against the old path and will not fire it again.
# Without this, the first save after upgrade records no session ID for any of
# them — and continuum overwrites the good sidecar within five minutes, so the
# IDs are gone before the user notices. Files whose assistants have since exited
# are harmless; reap_stale_state_files() clears them on the same pass.
migrate_legacy_state_files() {
	local rest
	rest=$(legacy_assistant_state_dirs)
	[ -n "$rest" ] || return 0

	local moved=0 sources="" legacy f nl=$'\n'
	# Walk the newline-separated list with parameter expansion. Deliberately not
	# `read` fed by a here-string: this script must contain no `<<<` at all (issue
	# #48 -- bash >= 5.1 writes one to a pipe before the reader is exec'd, and that
	# write can block forever under pipe-KVA pressure on macOS, hanging the hook).
	# test/run-tests.sh Test 11 greps for the construct and fails the build.
	while [ -n "$rest" ]; do
		legacy="${rest%%"$nl"*}"
		if [ "$legacy" = "$rest" ]; then
			rest=""
		else
			rest="${rest#*"$nl"}"
		fi

		[ -n "$legacy" ] || continue
		[ -d "$legacy" ] || continue
		# /tmp/tmux-assistant-resurrect is world-writable-parent and unscoped by uid:
		# on a shared box it may be another user's directory, or a symlink planted
		# where one was expected. Either way it holds nothing of ours to migrate --
		# our own pre-upgrade hook could not have written into it.
		[ -L "$legacy" ] && continue
		[ -O "$legacy" ] || continue

		local moved_here=0 dest
		for f in "$legacy"/claude-*.json "$legacy"/opencode-*.json; do
			[ -f "$f" ] || continue
			[ -O "$f" ] || continue

			dest="$STATE_DIR/$(basename "$f")"
			# Two files can claim one PID: a leftover whose PID was recycled, or the
			# same PID seen at two pre-upgrade roots. Neither the destination's mere
			# existence nor a root's probe position says which is current, so mtime
			# decides -- the hook writes just after its assistant starts, so the newer
			# file belongs to whoever holds the PID now. Always preferring $dest can
			# drop the only good copy and leave reap_stale_state_files() to delete the
			# stale one it kept. `-nt` is a bash builtin, so this costs no fork.
			if [ -e "$dest" ] && [ ! "$f" -nt "$dest" ]; then
				# `|| true` for the same reason as the `mv` below: under `set -e` a
				# bare `rm -f` that cannot unlink (a legacy root gone read-only) would
				# abort the save before assistant-sessions.json is written. Leaving the
				# older duplicate behind costs nothing — the destination already holds
				# the copy that wins.
				rm -f "$f" 2>/dev/null || true
				continue
			fi

			# `|| true` is load-bearing under `set -e`: a bare mv that fails -- a
			# read-only state dir, a cross-device legacy root -- would abort the whole
			# save before assistant-sessions.json is written, turning a skippable file
			# into total data loss for every pane. Failure here just leaves the file
			# where it is for the next save to retry.
			#
			# Not `mv -n`: the two userlands disagree on what a refusal even is (BSD
			# exits 0, GNU coreutils exits 1, so under `set -e` a perfectly normal
			# refusal would kill the hook on Linux), and it cannot express the
			# replace-the-stale-one case above anyway. The narrow window it would have
			# guarded -- a SessionStart hook writing $dest between the check and the
			# rename -- is bounded instead: rename preserves the source's mtime, so
			# reap_stale_state_files(), which main() runs on the next line, drops a
			# mis-migrated file on this same pass. The race costs a missing session ID,
			# never a wrong one.
			mv -f "$f" "$dest" 2>/dev/null || true
			[ -e "$f" ] || moved_here=$((moved_here + 1))
		done
		# Best-effort: only succeeds once the directory is empty, which is what we want.
		rmdir "$legacy" 2>/dev/null || true

		if [ "$moved_here" -gt 0 ]; then
			moved=$((moved + moved_here))
			sources="$sources $legacy"
		fi
	done

	[ "$moved" -gt 0 ] && log "migrated $moved state file(s) from legacy state dir(s):$sources"
	return 0
}

# Remove state files whose process is gone.
#
# The SessionEnd hook deletes a session's own file, but it never runs on SIGKILL,
# OOM, a crash, or a closed terminal. Under the old $TMPDIR/$XDG_RUNTIME_DIR
# default those leftovers were cleared at reboot; $HOME persists, so the save hook
# sweeps them itself. This bounds growth and, more importantly, shrinks the window
# in which a recycled PID matches an unrelated assistant's stale file and restores
# the wrong conversation.
#
# The PID comes from the filename (our own hooks write claude-<pid>.json), so the
# liveness check costs no forks — `kill -0` is a builtin. Files not matching the
# pattern are left alone rather than deleted, and the numeric guard mirrors
# `just clean`: without it a corrupt `pid: 0` file would survive forever, because
# `kill -0 0` signals the caller's own process group and always succeeds.
reap_stale_state_files() {
	local reaped=0 f base pid stale
	for f in "$STATE_DIR"/claude-*.json "$STATE_DIR"/opencode-*.json; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		pid="${base#*-}"
		pid="${pid%.json}"
		stale=0
		if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 1 ]; then
			stale=1
		elif ! kill -0 "$pid" 2>/dev/null; then
			stale=1
		# The PID is live — but is it still the same process? $HOME survives
		# reboots, and after a reboot every PID is recycled, so a leftover file
		# can land on an unrelated assistant and restore a stranger's
		# conversation into the pane. Same test as the Copilot lock: the hook
		# writes just after the assistant starts, so a file older than the
		# process claiming it belongs to a dead predecessor.
		elif _file_predates_process "$f" "$pid"; then
			stale=1
		fi
		[ "$stale" -eq 1 ] || continue

		# Tested rather than bare, for the same reason the `mv` in
		# migrate_legacy_state_files() carries `|| true`: this script runs under
		# `set -e`, and `rm -f` still fails on a file it cannot unlink (an
		# unwritable $STATE_DIR, an immutable file). A bare one would abort the
		# save before assistant-sessions.json is written, losing every pane's
		# session ID over one undeletable leftover. Counting only on success also
		# keeps the log honest — "reaped 3" must not include files still on disk.
		if rm -f "$f" 2>/dev/null; then
			reaped=$((reaped + 1))
		fi
	done
	[ "$reaped" -gt 0 ] && log "reaped $reaped stale state file(s)"
	return 0
}

# Explain where the save hook looked when it came up empty.
#
# "no session ID available" on its own is indistinguishable between "the hook
# never ran", "the hook ran but wrote somewhere this process cannot see" (the
# writer/reader path mismatch of issue #65) and "this assistant genuinely has no
# ID yet". Naming the path turns that into a one-look diagnosis.
missing_session_hint() {
	local tool="$1" pid="$2" state_file=""
	case "$tool" in
	claude) state_file="$STATE_DIR/claude-${pid}.json" ;;
	opencode) state_file="$STATE_DIR/opencode-${pid}.json" ;;
	*)
		echo "(no session ID in args)"
		return
		;;
	esac

	if [ -f "$state_file" ]; then
		echo "(state file $state_file holds no session_id; no session ID in args)"
		return
	fi

	# A live assistant in the pane but not one state file anywhere is the
	# signature of a path mismatch: the hook wrote to a directory this process
	# resolves differently.
	local found=""
	for found in "$STATE_DIR"/*.json; do
		[ -e "$found" ] && break
		found=""
	done
	if [ -z "$found" ]; then
		echo "(no $state_file, and no state files at all in $STATE_DIR — is the $tool hook installed, and does it resolve the same state dir? override both sides with TMUX_ASSISTANT_RESURRECT_DIR)"
	else
		echo "(no $state_file; no session ID in args)"
	fi
}

USED_CODEX_SESSION_IDS=""
USED_PI_SESSION_IDS=""
USED_OMP_SESSION_IDS=""

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

	# Method 2: session selector in process args (chicken-and-egg fallback).
	# After restore, claude is launched as `claude --resume <session_id>`, and
	# `claude --session-id <uuid>` names the session up front the same way.
	# If the SessionStart hook hasn't fired yet, the ID is still in the args.
	#
	# _arg_value is the same helper get_omp_session already uses. It handles
	# both `--flag <id>` and `--flag=<id>`, and it will not mistake a following
	# option for the value -- the old regex read `claude --resume --model opus`
	# as the session ID `--model`. Two calls rather than one so --resume keeps
	# precedence when both flags are present, as it did before.
	local sid
	sid=$(_arg_value "$args" --resume)
	[ -n "$sid" ] || sid=$(_arg_value "$args" --session-id)
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

# --- GitHub Copilot CLI ---
#
# A live Copilot session marks its own state directory with an
# `inuse.<pid>.lock` file (whose content is the same PID):
#
#   $COPILOT_HOME/session-state/<uuid>/inuse.<native-pid>.lock
#
# That is a PID -> session-ID mapping resolvable with one glob: no /proc, no
# lsof, no platform branch, and it works on native Windows too. The lock is
# written at TUI startup, before the first prompt. Copilot can leave the prior
# session's lock behind after an in-process `/resume`, so when one PID has
# multiple valid locks the newest lock is authoritative.
#
# Authenticated sessions may also open a per-session `session.db`, but that is
# not available in the pre-auth contract and mapping it to a PID needs
# platform-specific process inspection. The lock is the portable primary
# contract. test/copilot-contract-test.sh pins it against the real binary.

# COPILOT_HOME replaces the whole ~/.copilot path (same convention as GROK_HOME).
# The deprecated `--config-dir <path>` does the same thing per process and is
# still honored by 1.0.78 -- a session launched with it writes its lock there and
# nothing at all under ~/.copilot -- so it wins when present in the candidate's
# argv. Callers that have no argv handy may omit it.
copilot_session_state_dir() {
	local args="${1:-}"
	local pid="${2:-}"
	local root=""
	local tail=""
	case " $args " in
	*" --config-dir="*) tail="${args##*--config-dir=}" ;;
	*" --config-dir "*) tail="${args##*--config-dir }" ;;
	esac
	if [ -n "$tail" ]; then
		# `ps` has flattened the quoting, so a root containing spaces arrives as
		# several tokens. Prefer the longest prefix that is actually a directory
		# holding a session-state/, then fall back to the first token.
		local candidate="$tail"
		root="${tail%% *}"
		while [ -n "$candidate" ]; do
			if [ -d "$candidate/session-state" ]; then
				root="$candidate"
				break
			fi
			case "$candidate" in
			*" "*) candidate="${candidate% *}" ;;
			*) break ;;
			esac
		done
	fi
	# A tmux hook does not inherit the interactive shell's environment, so a
	# COPILOT_HOME exported from a shell profile is invisible here and the
	# session would be silently skipped. Read it from the Copilot process itself
	# where the kernel allows it (Linux/WSL). macOS cannot read another
	# process's environment unprivileged -- documented, same as capture-env.
	if [ -z "$root" ] && [ -n "$pid" ]; then
		root=$(_copilot_home_from_process "$pid")
	fi
	[ -n "$root" ] || root="${COPILOT_HOME:-$HOME/.copilot}"
	echo "$root/session-state"
}

_copilot_home_from_process() {
	local pid="$1"
	# COPILOT_PROC_ROOT is a test seam so the hermetic suite can exercise this
	# without a live process; production always reads the real /proc.
	local environ_file="${COPILOT_PROC_ROOT:-/proc}/${pid}/environ"
	# Open first: the process may exit between detection and inspection.
	{ exec 3<"$environ_file"; } 2>/dev/null || return 0
	local entry
	while IFS= read -r -d '' entry; do
		case "$entry" in
		COPILOT_HOME=?*)
			printf '%s' "${entry#COPILOT_HOME=}"
			break
			;;
		esac
	done <&3
	exec 3<&-
	return 0
}

# 8-4-4-4-12 hex. Glob-only so it costs no fork: the character class rejects
# anything but hex digits and dashes, and the `?` runs pin the dash positions.
_copilot_is_uuid() {
	[ "${#1}" -eq 36 ] || return 1
	case "$1" in
	*[!0-9a-fA-F-]*) return 1 ;;
	????????-????-????-????-????????????) return 0 ;;
	esac
	return 1
}

# Portable file mtime in epoch seconds: GNU stat, then BSD stat.
_file_mtime_epoch() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Portable high-resolution recency key: GNU stat first, then BSD stat.
# mtime orders normal session switches; ctime breaks ties when two lock mtimes
# land in the same second or are made equal by a filesystem/tooling quirk.
_file_recency_key() {
	LC_ALL=C stat -c '%y|%z' "$1" 2>/dev/null ||
		LC_ALL=C stat -f '%Fm|%Fc' "$1" 2>/dev/null
}

# Is a file that was written at process start older than the process now holding
# that PID? If so it belongs to a dead predecessor whose PID has been recycled,
# and trusting it would map the new process onto the dead session. Advisory: when
# either timestamp is unavailable, report "not stale" rather than lose a real
# session.
_file_predates_process() {
	local file="$1" pid="$2"
	local file_mtime proc_start
	file_mtime=$(_file_mtime_epoch "$file")
	[ -n "$file_mtime" ] || return 1
	proc_start=$(get_process_start_epoch "$pid")
	[ -n "$proc_start" ] || return 1
	# Slack: the macOS start time is derived from second-granular elapsed time.
	[ "$file_mtime" -lt "$((proc_start - 5))" ]
}

# A SIGKILLed Copilot leaves its lock behind. If that PID is later recycled by a
# new Copilot, the stale lock would map the new process onto the dead session.
# The lock is written at session start, so one older than the process claiming
# it is stale.
_copilot_lock_is_live() {
	! _file_predates_process "$1" "$2"
}

get_copilot_session_from_lock() {
	local child_pid="$1"
	local args="${2:-}"
	local state_dir="${3:-}"
	local lock sid recorded lock_key
	local newest_sid="" newest_key="" fallback_sid=""
	[ -n "$state_dir" ] || state_dir=$(copilot_session_state_dir "$args" "$child_pid")
	[ -d "$state_dir" ] || return 0

	for lock in "$state_dir"/*/"inuse.${child_pid}.lock"; do
		[ -f "$lock" ] || continue
		sid="${lock%/*}"
		sid="${sid##*/}"
		_copilot_is_uuid "$sid" || continue
		# Resumability gate. The lock appears at TUI startup, but Copilot only
		# writes session.db (and events.jsonl) once the session has real
		# content, and only such a session can be resumed -- `--resume=<uuid>`
		# on a still-empty one exits with "No session, task, or name matched".
		# Saving it would replay a command that errors in the user's pane, so
		# treat "no session.db yet" as "nothing to save yet".
		[ -f "${lock%/*}/session.db" ] || continue
		# The lock records its owner; a mismatch means we misread the layout.
		recorded=""
		IFS= read -r recorded <"$lock" 2>/dev/null || true
		[ -z "$recorded" ] || [ "$recorded" = "$child_pid" ] || continue
		_copilot_lock_is_live "$lock" "$child_pid" || continue
		[ -n "$fallback_sid" ] || fallback_sid="$sid"
		lock_key=$(_file_recency_key "$lock")
		[ -n "$lock_key" ] || continue
		if [ -z "$newest_key" ] || [[ "$lock_key" > "$newest_key" ]]; then
			newest_key="$lock_key"
			newest_sid="$sid"
		fi
	done
	[ -n "$newest_sid" ] && echo "$newest_sid" || echo "$fallback_sid"
	return 0
}

get_copilot_session() {
	local child_pid="$1"
	local args="$2"
	local allow_args_fallback="${3:-1}"
	local state_dir="${4:-}"
	local sid=""
	[ -n "$state_dir" ] || state_dir=$(copilot_session_state_dir "$args" "$child_pid")

	# Primary: PID-specific, platform-independent, and current after /resume.
	sid=$(get_copilot_session_from_lock "$child_pid" "$args" "$state_dir")
	if [ -n "$sid" ]; then
		echo "$sid"
		return 0
	fi

	# Fallback: explicit session selector in argv. Covers the startup window
	# before the lock exists and setups where the state root is unreadable.
	# Deferred to resolver pass 2 so a stale npm-loader argv cannot beat a live
	# lock held by the native child.
	[ "$allow_args_fallback" = "1" ] || return 0
	local uuid='\([0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}\)'
	local flag
	for flag in '--session-id' '--resume' '-r'; do
		sid=$(echo "$args" | sed -n "s/.*${flag}[= ] *$uuid.*/\1/p")
		if [ -n "$sid" ]; then
			# Same resumability gate as the lock path. `copilot --session-id
			# <uuid>` on a blank TUI puts a UUID in argv long before the session
			# can be resumed, so without this the fallback happily saves one
			# that restore can only fail on.
			[ -f "$state_dir/$sid/session.db" ] || continue
			echo "$sid"
			return 0
		fi
	done
	return 0
}

get_opencode_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"
	local allow_db_fallback="${4:-1}"

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
	if [ "$allow_db_fallback" = "1" ] && [ -n "$cwd" ] && [ -f "$db_file" ] && command -v python3 >/dev/null 2>&1; then
		sid=$(python3 "$PY_DIR/opencode_db.py" "$db_file" "$cwd" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

get_codex_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"

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

	# Method 3: Codex thread state DB (Codex >= ~0.118 persist state in
	# SQLite: ~/.codex/state_*.sqlite, table `threads`, columns id/cwd/
	# updated_at/archived).  This is the canonical current source — codex
	# writes a `threads` row per session and bumps `updated_at` on every
	# user turn.  A long-lived session that started days ago keeps its
	# same `id` in this table even though no new rollout JSONL is ever
	# written, which is exactly the case Method 4 misses.
	#
	# Strategy: among threads matching our process's cwd that are unarchived
	# and have been updated during this process's lifetime, pick the most
	# recently updated one that isn't already assigned to another pane.
	#
	# The DB file is versioned (state_5.sqlite, bumping on schema changes).
	# We glob for state_*.sqlite inside python3 (avoids `ls -t` pipe and
	# handles spaces in paths cleanly) and pick the newest by mtime.
	if [ -n "$cwd" ] && command -v python3 >/dev/null 2>&1; then
		local process_start
		process_start=$(get_process_start_epoch "$child_pid")
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 "$PY_DIR/codex_state_db.py" "$HOME/.codex" "$cwd" "$process_start"
		)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 4: Codex rollout session files (Codex ~0.100-0.117 wrote
	# these; newer versions have moved to SQLite, see Method 3).
	# Releases in that window persisted session metadata under
	# ~/.codex/sessions/*/*.jsonl and included a session_meta record
	# with both id and cwd.
	# We rank candidates by:
	# - matching cwd
	# - preferring session IDs not already assigned during this save
	# - preferring sessions created before the current process start time
	# - preferring sessions closest to the current process start time
	# - preferring recently modified rollout files
	local sessions_root="${HOME}/.codex/sessions"
	if [ -n "$cwd" ] && [ -d "$sessions_root" ] && command -v python3 >/dev/null 2>&1; then
		local process_start
		process_start=$(get_process_start_epoch "$child_pid")
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 "$PY_DIR/codex_rollout.py" "$sessions_root" "$cwd" "$process_start"
		)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

_arg_value() {
	local args="$1"
	shift
	# Disable pathname expansion while splitting: an argv value containing a
	# glob char (e.g. `--cwd '*'`) would otherwise expand against the cwd and
	# resolve the wrong session directory. Preserve the caller's noglob state
	# so we never re-enable globbing for a caller that had it off.
	local -a words
	local _had_noglob=0
	case $- in *f*) _had_noglob=1 ;; esac
	set -f
	# shellcheck disable=SC2206  # deliberate word-split of argv string; globbing disabled above
	words=($args)
	[ "$_had_noglob" = 1 ] || set +f
	local i n word flag next
	n=${#words[@]}
	for ((i = 0; i < n; i++)); do
		word="${words[$i]}"
		for flag in "$@"; do
			case "$word" in
			"$flag="*)
				echo "${word#*=}"
				return
				;;
			"$flag")
				next=$((i + 1))
				if [ "$next" -lt "$n" ]; then
					case "${words[$next]}" in
					-*) ;;
					*)
						echo "${words[$next]}"
						return
						;;
					esac
				fi
				;;
			esac
		done
	done
	return 0
}

resolve_path_against() {
	local base="$1"
	local path="$2"
	case "$path" in
	/*)
		echo "$path"
		;;
	*)
		if command -v python3 >/dev/null 2>&1; then
			python3 "$PY_DIR/resolve_path.py" "$base" "$path"
		else
			echo "${base%/}/$path"
		fi
		;;
	esac
}

jsonl_session_id_from_file() {
	local session_file="$1"
	[ -f "$session_file" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	python3 "$PY_DIR/jsonl_header_sid.py" "$session_file"
}

select_jsonl_session_id() {
	local child_pid="$1"
	local cwd="$2"
	local used_ids="$3"
	shift 3
	[ -n "$cwd" ] || return 0
	[ "$#" -gt 0 ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0

	local process_start
	process_start=$(get_process_start_epoch "$child_pid")
	python3 "$PY_DIR/select_jsonl_session.py" "$cwd" "$process_start" "$used_ids" "$@"
}

get_pi_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"

	# Method 1: --session flag in process args (chicken-and-egg fallback)
	# After restore, pi is launched as `pi --session <session_id>`.
	# Supports both `--session <id>` and `--session=<id>` forms.
	local sid
	sid=$(echo "$args" | sed -n 's/.*--session[= ] *\([A-Za-z0-9_-]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: session files under ~/.pi/agent/sessions/--<cwd>--.
	# Pi writes one JSONL file per session with a session header. The shared
	# selector keeps the existing process-time scoring and same-cwd dedup policy.
	local sessions_root="${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.pi/agent/sessions}"
	if [ -n "$cwd" ] && [ -d "$sessions_root" ]; then
		local safe_cwd session_dir
		safe_cwd=$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')
		session_dir="${sessions_root}/--${safe_cwd}--"
		sid=$(select_jsonl_session_id "$child_pid" "$cwd" "$USED_PI_SESSION_IDS" "$session_dir")
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

omp_config_root() {
	echo "${PI_CONFIG_DIR:-${HOME}/.omp}"
}

omp_agent_dir() {
	local profile="$1"
	local config_root
	config_root=$(omp_config_root)
	if [ -n "$profile" ]; then
		echo "${config_root}/profiles/${profile}/agent"
	elif [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
		echo "$PI_CODING_AGENT_DIR"
	else
		echo "${config_root}/agent"
	fi
}

omp_session_root() {
	local profile="$1"
	local xdg_data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
	local config_root
	config_root=$(omp_config_root)
	if [ -n "$profile" ]; then
		if [ -d "${xdg_data_home}/omp/profiles/${profile}" ]; then
			echo "${xdg_data_home}/omp/profiles/${profile}/sessions"
		else
			echo "${config_root}/profiles/${profile}/agent/sessions"
		fi
	elif [ -d "${xdg_data_home}/omp" ]; then
		echo "${xdg_data_home}/omp/sessions"
	elif [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
		echo "${PI_CODING_AGENT_DIR}/sessions"
	else
		echo "${config_root}/agent/sessions"
	fi
}

omp_terminal_session_root() {
	local profile="$1"
	local xdg_state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
	if [ -n "$profile" ]; then
		if [ -d "${xdg_state_home}/omp/profiles/${profile}" ]; then
			echo "${xdg_state_home}/omp/profiles/${profile}/terminal-sessions"
		else
			echo "$(omp_agent_dir "$profile")/terminal-sessions"
		fi
	elif [ -d "${xdg_state_home}/omp" ]; then
		echo "${xdg_state_home}/omp/terminal-sessions"
	else
		echo "$(omp_agent_dir "")/terminal-sessions"
	fi
}

omp_terminal_id_from_tty() {
	local pane_tty="$1"
	pane_tty="${pane_tty#/dev/}"
	echo "$pane_tty" | sed -e 's#[/\\:]#-#g'
}

omp_sanitize_path_name() {
	echo "$1" | sed -e 's#[/\\:]#-#g'
}

omp_session_dir_names() {
	local cwd="$1"
	local home="${HOME%/}"
	local tmp="${TMPDIR:-/tmp}"
	tmp="${tmp%/}"
	local primary rel legacy
	case "$cwd" in
	"$home")
		primary="-"
		;;
	"$home"/*)
		rel="${cwd#"$home"/}"
		primary="-$(omp_sanitize_path_name "$rel")"
		;;
	"$tmp")
		primary="-tmp"
		;;
	"$tmp"/*)
		rel="${cwd#"$tmp"/}"
		primary="-tmp-$(omp_sanitize_path_name "$rel")"
		;;
	*)
		primary="--$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')--"
		;;
	esac
	legacy="--$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')--"
	echo "$primary"
	[ "$legacy" != "$primary" ] && echo "$legacy"
}

get_omp_breadcrumb_session() {
	local pane_tty="$1"
	local lookup_cwd="$2"
	local profile="$3"
	[ -n "$pane_tty" ] || return 0
	[ -n "$lookup_cwd" ] || return 0

	local terminal_id root breadcrumb recorded_cwd session_file sid
	terminal_id=$(omp_terminal_id_from_tty "$pane_tty")
	[ -n "$terminal_id" ] || return 0
	root=$(omp_terminal_session_root "$profile")
	breadcrumb="${root}/${terminal_id}"
	[ -f "$breadcrumb" ] || return 0

	{
		IFS= read -r recorded_cwd || true
		IFS= read -r session_file || true
	} <"$breadcrumb"
	[ "$recorded_cwd" = "$lookup_cwd" ] || return 0
	[ -f "$session_file" ] || return 0

	sid=$(jsonl_session_id_from_file "$session_file")
	if [ -n "$sid" ]; then
		echo "$sid"
	fi
}

get_omp_session() {
	local child_pid="$1"
	local args="$2"
	local pane_cwd="${3:-}"
	local pane_tty="${4:-}"

	local sid
	sid=$(_arg_value "$args" --resume -r --session)
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	local lookup_cwd="$pane_cwd"
	local cwd_arg
	cwd_arg=$(_arg_value "$args" --cwd)
	if [ -n "$cwd_arg" ]; then
		lookup_cwd=$(resolve_path_against "$pane_cwd" "$cwd_arg")
	fi

	local profile
	profile=$(_arg_value "$args" --profile)

	sid=$(get_omp_breadcrumb_session "$pane_tty" "$lookup_cwd" "$profile")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	local custom_session_dir
	custom_session_dir=$(_arg_value "$args" --session-dir)
	if [ -n "$custom_session_dir" ]; then
		custom_session_dir=$(resolve_path_against "$lookup_cwd" "$custom_session_dir")
		sid=$(select_jsonl_session_id "$child_pid" "$lookup_cwd" "$USED_OMP_SESSION_IDS" "$custom_session_dir")
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	local session_root dir_name
	local -a session_dirs=()
	session_root=$(omp_session_root "$profile")
	while IFS= read -r dir_name; do
		[ -n "$dir_name" ] && session_dirs+=("${session_root}/${dir_name}")
	done < <(omp_session_dir_names "$lookup_cwd")
	sid=$(select_jsonl_session_id "$child_pid" "$lookup_cwd" "$USED_OMP_SESSION_IDS" "${session_dirs[@]}")
	if [ -n "$sid" ]; then
		echo "$sid"
	fi
}

# Resolve grok's active-sessions registry path. grok records every live
# interactive session in ~/.grok/active_sessions.json as an array of
#   { "session_id": "<uuid>", "pid": <int>, "cwd": "<path>", "opened_at": "..." }
# and updates it on session open/close. GROK_HOME lets tests (and unusual
# installs) point this at a fixture directory.
grok_active_sessions_file() {
	echo "${GROK_HOME:-$HOME/.grok}/active_sessions.json"
}

get_grok_session() {
	local child_pid="$1"
	local args="$2"

	# Method 1 (primary): PID lookup in grok's active-sessions registry.
	# Authoritative for every running session regardless of launch form — a
	# bare `grok` (no args) is recorded here with its session_id — and lookup
	# is keyed by PID, so two sessions sharing a cwd never collide (the
	# cwd-scoped ambiguity that opencode/codex/pi fallbacks suffer from does
	# not apply to grok).
	local registry sid
	registry=$(grok_active_sessions_file)
	if [ -f "$registry" ]; then
		sid=$(jq -r --arg pid "$child_pid" \
			'.[]? | select((.pid | tostring) == $pid) | .session_id // empty' \
			"$registry" 2>/dev/null | head -n1 || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2 (fallback): -r/--resume <uuid> in process args. Covers the
	# chicken-and-egg window right after a restore, before grok has rewritten
	# active_sessions.json. Anchored to a 36-char UUID so a trailing prompt
	# positional can't be mistaken for the ID. Handles `--resume <id>`,
	# `--resume=<id>`, `-r <id>`, and `-r=<id>`.
	sid=$(echo "$args" | sed -n 's/.*--resume[= ] *\([0-9a-fA-F]\{8\}-[0-9a-fA-F-]\{27\}\).*/\1/p')
	[ -z "$sid" ] && sid=$(echo "$args" | sed -n 's/.*-r[= ] *\([0-9a-fA-F]\{8\}-[0-9a-fA-F-]\{27\}\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

register_codex_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_CODEX_SESSION_IDS"$'\t' in
	*$'\t'"$sid"$'\t'*) ;;
	*)
		USED_CODEX_SESSION_IDS="${USED_CODEX_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

register_pi_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_PI_SESSION_IDS"$'\t' in
	*$'\t'"$sid"$'\t'*) ;;
	*)
		USED_PI_SESSION_IDS="${USED_PI_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

register_omp_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_OMP_SESSION_IDS"$'\t' in
	*$'\t'"$sid"$'\t'*) ;;
	*)
		USED_OMP_SESSION_IDS="${USED_OMP_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

# Wall-clock start time of a process, as a Unix epoch (seconds). Prints nothing
# when it can't be determined. Session matching uses this to tell the live
# assistant session apart from stale sessions sharing the same cwd; without it,
# matching degrades to "newest session in this cwd" and can restore the wrong one.
#
# Linux reads /proc/PID/stat directly with the shell's `read` builtin — no
# fork/exec, matching read_process_env() and ~30x cheaper than spawning ps.
# macOS/BSD have no /proc, so fall back to elapsed time (`ps -o etime=`) there.
# (The old `ps -o etimes=` used everywhere was a GNU keyword BSD ps rejects, so
# it silently produced nothing on macOS — see issue #49.)
get_process_start_epoch() {
	local pid="$1"
	[ -n "$pid" ] || return 0

	local stat_file="/proc/${pid}/stat"
	if [ -r "$stat_file" ]; then
		local stat_line
		IFS= read -r stat_line <"$stat_file" 2>/dev/null || return 0
		# comm (field 2) is parenthesized and may contain spaces or ')', so
		# slice past the final ')'. What remains starts at state (field 3);
		# starttime (field 22, clock ticks since boot) is then index 19.
		local rest="${stat_line##*)}"
		local -a fields
		# shellcheck disable=SC2206  # deliberate word-split on numeric fields
		fields=($rest)
		local starttime="${fields[19]}"
		case "$starttime" in
		'' | *[!0-9]*) return 0 ;;
		esac

		# Boot time (epoch) from /proc/stat; clock ticks/sec from getconf.
		local btime="" line
		while IFS= read -r line; do
			case "$line" in
			'btime '*)
				btime="${line#btime }"
				break
				;;
			esac
		done </proc/stat
		case "$btime" in
		'' | *[!0-9]*) return 0 ;;
		esac

		local hz
		hz=$(getconf CLK_TCK 2>/dev/null)
		case "$hz" in
		'' | *[!0-9]*) hz=100 ;;
		esac

		echo "$((btime + starttime / hz))"
		return 0
	fi

	# Non-Linux (macOS/BSD): no /proc. Derive the start from *elapsed* time
	# (`ps -o etime=`) rather than an absolute wall-clock timestamp. Elapsed time
	# is a plain duration, so — unlike parsing `ps -o lstart=` — it carries no
	# timezone, DST-repeated-hour, or locale ambiguity. Absolute /bin paths so a
	# PATH with Homebrew coreutils ahead of /bin can't shadow the system ps/date
	# with GNU builds (see issue #49 review).
	local etime seconds
	etime=$(/bin/ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
	seconds=$(_etime_to_seconds "$etime")
	[ -n "$seconds" ] || return 0
	echo "$(($(/bin/date +%s) - seconds))"
}

# Convert a BSD `ps -o etime=` elapsed time ("[[dd-]hh:]mm:ss") to whole seconds,
# or print nothing if it doesn't match. Pure arithmetic — no date binary, locale,
# or timezone involved. Split out so the day-component cases (with and without the
# leading "dd-") are unit testable without a live process (see issue #49).
_etime_to_seconds() {
	local etime="$1" days=0 rest
	[ -n "$etime" ] || return 0
	# Optional leading "dd-" day count.
	case "$etime" in
	*-*)
		days=${etime%%-*}
		rest=${etime#*-}
		;;
	*)
		rest=$etime
		;;
	esac
	# rest is [hh:]mm:ss — split on ':'. Feed it through a process substitution
	# (concurrent reader) rather than a `<<<` here-string: on bash >= 5.1 a
	# here-string is written to a pipe before its reader runs and can block on
	# macOS under pipe-memory pressure — the same failure mode as issue #48.
	local -a parts
	IFS=: read -r -a parts < <(printf '%s' "$rest")
	local hours mins secs
	case "${#parts[@]}" in
	3) hours=${parts[0]} mins=${parts[1]} secs=${parts[2]} ;;
	2) hours=0 mins=${parts[0]} secs=${parts[1]} ;;
	*) return 0 ;;
	esac
	# Every component must be a non-empty run of digits.
	local part
	for part in "$days" "$hours" "$mins" "$secs"; do
		case "$part" in
		'' | *[!0-9]*) return 0 ;;
		esac
	done
	# 10# forces base-10 so zero-padded fields (e.g. "08") aren't read as octal.
	echo "$((10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs))"
}

# Merge one advisory relaunch candidate into the user-visible ledger. Process
# lifetime is only a ranking hint: it never participates in voucher matching or
# restore authorization. Entries unseen for 30 days are pruned and the 200 most
# recently observed entries are retained.
relaunch_ledger_apply() {
	local tool="$1" canon="$2" pid="$3"
	local now_epoch now_iso start_epoch lifetime=0 cutoff existing tmp
	now_epoch=$(date +%s)
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	start_epoch=$(get_process_start_epoch "$pid")
	case "$start_epoch" in
	'' | *[!0-9]*) ;;
	*)
		if [ "$start_epoch" -le "$now_epoch" ]; then
			lifetime=$((now_epoch - start_epoch))
		fi
		;;
	esac
	cutoff=$((now_epoch - 30 * 24 * 60 * 60))

	if [ -f "$RELAUNCH_LEDGER_FILE" ]; then
		existing=$(sed -n '1,$p' "$RELAUNCH_LEDGER_FILE" 2>/dev/null || printf '[]')
	else
		existing='[]'
	fi
	tmp=$(mktemp "${RELAUNCH_LEDGER_FILE}.tmp.XXXXXX") || return 1
	RELAUNCH_LEDGER_TMP="$tmp"
	if ! (umask 077 && jq -Rn \
		--arg existing "$existing" \
		--arg tool "$tool" \
		--arg cmd "$canon" \
		--arg now_iso "$now_iso" \
		--argjson now "$now_epoch" \
		--argjson cutoff "$cutoff" \
		--argjson lifetime "$lifetime" '
		($existing | try fromjson catch []) as $decoded |
		(if ($decoded | type) == "array" then $decoded else [] end) as $entries |
		($entries | map(select((.last_seen_epoch // 0) >= $cutoff))) as $fresh |
		($fresh | map(select(.tool == $tool and .cmd == $cmd)) | first // {}) as $prior |
		($fresh
		 | map(select(.tool != $tool or .cmd != $cmd))
		 | . + [{
			tool: $tool,
			cmd: $cmd,
			seen: (($prior.seen // 0) + 1),
			longest_seconds: ([($prior.longest_seconds // 0), $lifetime] | max),
			first_seen: ($prior.first_seen // $now_iso),
			last_seen: $now_iso,
			last_seen_epoch: $now
		  }]
		 | sort_by(.last_seen_epoch) | reverse | .[:200])
	' >"$tmp"); then
		rm -f "$tmp"
		RELAUNCH_LEDGER_TMP=""
		return 1
	fi
	mv -f "$tmp" "$RELAUNCH_LEDGER_FILE"
	RELAUNCH_LEDGER_TMP=""
}

# Handle the shared no-session-ID path used by both the batched resolver and
# legacy emit_session(). Shape only controls whether the command is proposed in
# the ledger. A hand-written exact voucher can authorize a shape-rejected line;
# conversely, a shape-ok line is never authorization by itself.
handle_sessionless_relaunch() {
	local target="$1" tool="$2" pid="$3" raw_args="$4" cwd="$5"
	local log_missing="${6:-1}"
	local prefix
	prefix="detected $tool in $target (pid $pid) but no session ID available $(missing_session_hint "$tool" "$pid")"
	local canon="" vouched_line="" shape_ok=0 relaunch_parts

	case "$RELAUNCH_ENABLED" in
	on | yes | true | 1) ;;
	*)
		[ "$log_missing" = "1" ] && log "$prefix: relaunch disabled"
		return 1
		;;
	esac

	canon=$(relaunch_canon "$tool" "$raw_args") || {
		[ "$log_missing" = "1" ] && log "$prefix: relaunch argv could not be canonicalized"
		return 1
	}

	if relaunch_shape_ok "$canon"; then
		shape_ok=1
		if ! relaunch_ledger_apply "$tool" "$canon" "$pid"; then
			log "warning: failed to update relaunch candidates ledger for $canon"
		fi
	fi

	vouched_line=$(relaunch_voucher_match "$tool" "$canon") || {
		if [ "$log_missing" = "1" ]; then
			if [ "$shape_ok" -eq 1 ]; then
				log "$prefix: relaunch cmd not vouched: $canon"
			else
				log "$prefix: relaunch shape rejected: $canon"
			fi
		fi
		return 1
	}

	relaunch_parts="${RELAUNCH_PARTS_FILE:-}"
	if [ -z "$relaunch_parts" ] && [ -n "${PARTS_FILE:-}" ]; then
		relaunch_parts="${PARTS_FILE}.relaunch"
		RELAUNCH_PARTS_FILE="$relaunch_parts"
	fi
	if [ -z "$relaunch_parts" ]; then
		log "warning: no relaunch parts file available for $canon"
		return 1
	fi

	# Five fields by design: keep the established session TSV schema untouched.
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$target" "$tool" "$cwd" "$pid" "$vouched_line" >>"$relaunch_parts"
	[ "$log_missing" = "1" ] && log "$prefix: relaunch vouched: $vouched_line"
	return 0
}

# Read user-configured variables directly from a detected assistant process.
# Claude and OpenCode normally provide these through their session hooks, but
# tools without hooks (including Codex) need save-time process inspection.
#
# Linux exposes the environment as NUL-delimited records in /proc. Other
# platforms retain the existing hook-only behavior by returning null.
read_process_env() {
	local pid="$1"
	local environ_file="/proc/${pid}/environ"

	if [ -z "$CAPTURE_ENV" ]; then
		echo "null"
		return
	fi

	# Open first so a process exiting between detection and inspection cannot
	# turn the best-effort capture into a fatal redirection error.
	if ! { exec 3<"$environ_file"; } 2>/dev/null; then
		echo "null"
		return
	fi

	local env_json="{}" entry name value
	while IFS= read -r -d '' entry; do
		name="${entry%%=*}"
		[ "$name" != "$entry" ] || continue
		[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
		case " $CAPTURE_ENV " in
		*" $name "*)
			value="${entry#*=}"
			# Feed the accumulator through a pipe (concurrent reader) rather
			# than a here-string: a `<<<` write happens before jq is exec'd and
			# can block if the pipe buffer cannot grow (see PY_DIR note above).
			env_json=$(printf '%s' "$env_json" | jq -c --arg key "$name" --arg value "$value" \
				'. + {($key): $value}')
			;;
		esac
	done <&3
	exec 3<&-

	if [ "$env_json" = "{}" ]; then
		echo "null"
	else
		echo "$env_json"
	fi
}

# Merge save-time process variables over hook-captured values. The running
# process is authoritative for variables explicitly requested by the user.
merge_process_env() {
	local pid="$1"
	local saved_env="${2:-null}"
	local process_env
	process_env=$(read_process_env "$pid")
	if [ -z "$process_env" ] || [ "$process_env" = "null" ]; then
		echo "${saved_env:-null}"
		return
	fi

	jq -nc \
		--argjson saved "${saved_env:-null}" \
		--argjson process "$process_env" \
		'($saved // {}) + $process'
}

# --- CLI args extraction helpers ---

# Copilot's variadic options -- the ones whose --help spelling ends in `...`,
# e.g. `--allow-tool[=tools...]`. They legitimately occupy several argv tokens.
SESSION_VARIADIC_FALLBACK_copilot="--allow-tool --allow-url --available-tools --deny-tool --deny-url --excluded-tools --secret-env-vars"

_copilot_variadic_flags() {
	local cached="${_COPILOT_VARIADIC_FLAGS:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	local help_out result=""
	help_out=$(_tool_help copilot)
	if [ -n "$help_out" ]; then
		result=$(echo "$help_out" |
			grep -E '^[[:space:]]+(-[a-zA-Z],[[:space:]]+)?--[a-z][-a-z]*\[=[^]]*\.\.\.\]' |
			grep -oE -- '--[a-z][-a-z]*' | sort -u | tr '\n' ' ')
		result="${result% }"
	fi
	[ -n "$result" ] || result="$SESSION_VARIADIC_FALLBACK_copilot"

	printf -v _COPILOT_VARIADIC_FLAGS '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Exact argv, boundaries intact, from /proc/<pid>/cmdline (NUL-separated).
# `ps` flattens argv and destroys the quoting, which makes a single value
# containing spaces indistinguishable from several values -- and for Copilot's
# variadic permission options (`--deny-tool 'shell(git push)'` vs `--deny-tool a
# b`) guessing wrong silently changes what the agent is allowed to do. Linux and
# WSL do not have to guess. macOS has no equivalent readable interface, so it
# falls back to the heuristic below and errs toward dropping.
#
# Emits the arguments after the binary (and after a node launcher's script path),
# one per line. Prints nothing when /proc is unavailable.
_copilot_exact_argv() {
	local pid="$1"
	[ -n "$pid" ] || return 0
	local cmdline="/proc/${pid}/cmdline"
	[ -r "$cmdline" ] || return 0

	local tok i=0
	while IFS= read -r tok; do
		i=$((i + 1))
		# Skip argv[0], and a second token that is the script path of a node
		# launcher -- mirrors the prefix stripping extract_cli_args does.
		if [ "$i" -eq 1 ]; then continue; fi
		if [ "$i" -eq 2 ]; then
			case "$tok" in
			*/copilot) continue ;;
			esac
		fi
		printf '%s\n' "$tok"
	done < <(tr '\0' '\n' <"$cmdline" 2>/dev/null)
	return 0
}

# Options that *restrict* the agent: a denial, an exclusion, or a whitelist that
# implies everything else is off. Losing one of these makes the restored session
# more powerful than the user asked for, so ambiguity must not preserve a guess
# and no other replay flag can safely survive alongside it.
#
# Deliberately excludes the granting options (--allow-*, --add-dir): dropping a
# grant only ever narrows what the agent can do, which is the safe direction.
_copilot_is_restriction_flag() {
	case "$1" in
	--deny-* | --available-tools | --excluded-tools) return 0 ;;
	esac
	return 1
}

# Rebuild cli_args from exact argv, dropping any value that cannot survive the
# whitespace-joined `cli_args` field along with the option it belongs to.
_copilot_args_from_exact_argv() {
	local pid="$1"
	local -a argv=() out=()
	local tok dropped_permission=0
	while IFS= read -r tok; do
		argv[${#argv[@]}]="$tok"
	done < <(_copilot_exact_argv "$pid")
	[ "${#argv[@]}" -gt 0 ] || return 1

	local i last
	for ((i = 0; i < ${#argv[@]}; i++)); do
		tok="${argv[$i]}"
		case "$tok" in
		*[[:space:]]*)
			# Unrepresentable once joined by spaces. An equals-form option is
			# self-contained, so drop that token itself; a separate value drops
			# the preceding option. In both forms, report a lost restriction.
			case "$tok" in
			-*=*)
				_copilot_is_restriction_flag "${tok%%=*}" && dropped_permission=1
				;;
			*)
				if [ "${#out[@]}" -gt 0 ]; then
					last="${out[$((${#out[@]} - 1))]}"
					case "$last" in
					-*)
						_copilot_is_restriction_flag "${last%%=*}" && dropped_permission=1
						unset "out[$((${#out[@]} - 1))]"
						out=(${out[@]+"${out[@]}"})
						;;
					esac
				fi
				;;
			esac
			;;
		*) out[${#out[@]}]="$tok" ;;
		esac
	done
	[ "${#out[@]}" -gt 0 ] && printf '%s' "${out[*]}"
	# These helpers run inside $(), where a variable assignment would be
	# discarded, so the permission drop is reported through the exit status.
	[ "$dropped_permission" -eq 1 ] && return 9
	return 0
}

# Copilot accepts zero positional arguments, so every bare token in its argv is
# an option value. `ps` has already lost the quoting, so a value that contained
# spaces arrives as several bare tokens -- and `cli_args` is a whitespace-joined
# string that cannot express it again. Restore would replay the extra words as
# positionals and Copilot exits with "too many arguments" before it can resume.
#
# Drop those options instead: a session that resumes with one flag missing beats
# a command line Copilot rejects outright. Variadic options are exempt because
# their several tokens round-trip correctly. Discovering the *variadic* set
# (rather than the single-valued one) is the fail-safe direction: if --help is
# unavailable we drop slightly too much rather than emit something invalid.
_copilot_drop_flattened_values() {
	local args="$1"
	local variadic
	variadic=" $(_copilot_variadic_flags) "

	# Word-split with pathname expansion off: argv is data, and a legitimate
	# quoted value such as `--allow-tool '*'` must not be expanded against the
	# save hook's working directory and persisted as a list of filenames.
	local reglob=""
	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2206  # deliberate word-split of a flattened argv
	local -a words=($args)
	[ -n "$reglob" ] && set +f

	local -a out=()
	local -a run=()
	local i=0 n=${#words[@]} last_flag="" last_had_eq=0 keep w
	local dropped_permission=0

	while [ "$i" -lt "$n" ]; do
		case "${words[$i]}" in
		-*)
			out[${#out[@]}]="${words[$i]}"
			last_flag="${words[$i]%%=*}"
			# `--flag=value` carries its own boundary, so anything bare that
			# follows can only be the rest of a value whose quoting was lost.
			last_had_eq=0
			case "${words[$i]}" in
			*=*) last_had_eq=1 ;;
			esac
			i=$((i + 1))
			continue
			;;
		esac

		# Collect the whole run of consecutive bare tokens.
		run=()
		while [ "$i" -lt "$n" ]; do
			case "${words[$i]}" in
			-*) break ;;
			esac
			run[${#run[@]}]="${words[$i]}"
			i=$((i + 1))
		done

		# One bare token after a space-form option is its value, and unambiguous.
		#
		# The variadic exemption applies only to the space form: `--deny-tool a b`
		# really is two values, but `--deny-tool='shell(git push)'` reaches ps as
		# `--deny-tool=shell(git push)` and Copilot then reads the fragment as a
		# positional ("too many arguments"). An equals sign already delimited the
		# value, so anything bare after it is a leak either way.
		# Without exact argv we cannot tell `--deny-tool 'shell(git push)'` from
		# `--deny-tool a b`. For a *restricting* option, guessing wrong installs
		# a rule the user never wrote and quietly widens what the agent may do,
		# so ambiguity drops even though the option is variadic. Granting
		# options keep the exemption: mis-splitting one only narrows access.
		keep=1
		if [ "$last_had_eq" -eq 1 ]; then
			keep=0
		elif [ "${#run[@]}" -gt 1 ]; then
			keep=0
			if ! _copilot_is_restriction_flag "$last_flag"; then
				case "$variadic" in
				*" $last_flag "*) keep=1 ;;
				esac
			fi
		fi
		if [ "$keep" -eq 0 ] && _copilot_is_restriction_flag "$last_flag"; then
			dropped_permission=1
		fi

		if [ "$keep" -eq 1 ]; then
			for w in "${run[@]}"; do
				out[${#out[@]}]="$w"
			done
		elif [ -n "$last_flag" ] && [ "${#out[@]}" -gt 0 ]; then
			# Drop the option the unreconstructable value belonged to.
			unset "out[$((${#out[@]} - 1))]"
			out=(${out[@]+"${out[@]}"})
		fi
		last_had_eq=0
		last_flag=""
	done

	[ "${#out[@]}" -gt 0 ] && echo "${out[*]}"
	[ "$dropped_permission" -eq 1 ] && return 9
	return 0
}

# Strip a long option: --flag, --flag=val, or --flag val.
# Value (if space-separated) must not start with "-" to avoid consuming next flag.
_strip_long_opt() {
	echo "$2" | sed -E "s/(^| )$1(=[^ ]*| +[^- ][^ ]*)?( |$)/ /g"
}

# Strip a short option: -X or -X val.
_strip_short_opt() {
	echo "$2" | sed -E "s/(^| )$1( +[^- ][^ ]*)?( |$)/ /g"
}

# Strip a boolean long option (no value): --flag
_strip_bool_opt() {
	echo "$2" | sed -E "s/(^| )$1( |$)/ /g"
}

# Strip known subcommands from args (e.g. "resume <id>" or "fork <id>").
# Usage: _strip_subcmds "args" subcmd1 subcmd2 ...
#
# Scans all args left-to-right. Each non-dash token is checked against the
# list of known subcommands. If it matches, the token and an optional
# following positional value (non-dash) are removed. Non-matching bare
# tokens (e.g. option values like "o3" in `--model o3 resume`) are
# skipped — scanning continues past them to find the actual subcommand.
_strip_subcmds() {
	# shellcheck disable=SC2206  # deliberate word-split of argv string
	local -a words=($1)
	shift
	local -a targets=("$@")
	local i=0 n=${#words[@]}
	while [ "$i" -lt "$n" ]; do
		case "${words[$i]}" in
		-*) i=$((i + 1)) ;;
		*)
			local matched=0 t
			for t in "${targets[@]}"; do
				if [ "${words[$i]}" = "$t" ]; then
					matched=1
					unset 'words[i]'
					local nxt=$((i + 1))
					if [ "$nxt" -lt "$n" ]; then
						case "${words[$nxt]}" in
						-*) ;;
						*) unset 'words[nxt]'; i=$((i + 1)) ;;
						esac
					fi
					break
				fi
			done
			i=$((i + 1))
			;;
		esac
	done
	[ "${#words[@]}" -gt 0 ] && echo "${words[*]}"
	return 0
}

# Run `<tool> --help`, neutralizing any side effects the tool performs on
# startup. The save hook fires every few minutes, so a probe that phones home is
# not acceptable: Copilot's native binary runs its auto-updater unless told not
# to. Per-tool overrides live in HELP_PROBE_ENV_<tool> (word-split on purpose).
HELP_PROBE_ENV_copilot="COPILOT_AUTO_UPDATE=false"

# Cached per tool in _TOOL_HELP_<tool>: several discovery passes read the same
# help text, and the callers run in a $() subshell per pane.
# shellcheck disable=SC2178,SC2128  # out is a plain string; printf -v writes to a dynamic name
_tool_help() {
	local tool="$1"
	local cache_var="_TOOL_HELP_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || printf '%s\n' "$cached"
		return 0
	fi

	local probe_env_var="HELP_PROBE_ENV_${tool}"
	local probe_env="${!probe_env_var:-}"
	local out=""
	if [ -n "$probe_env" ]; then
		# shellcheck disable=SC2086  # deliberate split into env KEY=VAL args
		out=$(env $probe_env "$tool" --help 2>/dev/null) || out=""
	else
		out=$("$tool" --help 2>/dev/null) || out=""
	fi

	printf -v "$cache_var" '%s' "${out:--}"
	[ -n "$out" ] && printf '%s\n' "$out"
	return 0
}

# Static value-taking option fallbacks for when a running assistant is not on
# the save hook's PATH. Dynamic discovery below is authoritative when --help is
# available; these keep common replay settings intact in the degraded path.
OPTION_VALUE_FLAGS_FALLBACK_claude="--add-dir --agent --agents --allowedTools --allowed-tools --append-system-prompt --autocompact --betas --cloud -d --debug --debug-file --disallowedTools --disallowed-tools --effort --environment --fallback-model --file --input-format --json-schema --max-budget-usd --mcp-config --model -n --name --output-format --permission-mode --plugin-dir --plugin-url --prompt-suggestions --remote-control --remote-control-session-name-prefix --setting-sources --settings --system-prompt --teleport --tools -w --worktree"
OPTION_VALUE_FLAGS_FALLBACK_copilot="--add-dir --add-github-mcp-tool --add-github-mcp-toolset --additional-mcp-config --agent --allow-tool --allow-url --attachment --available-tools --bash-env -C --context --deny-tool --deny-url --disable-mcp-server --effort --reasoning-effort --excluded-tools --extension-sdk-path --log-dir --log-level --max-ai-credits --max-autopilot-continues --mode --model --mouse --output-format --plugin-dir --secret-env-vars --share --stream"
OPTION_VALUE_FLAGS_FALLBACK_opencode="--log-level --port --hostname --mdns-domain --cors -m --model --prompt --agent --replay-limit"
OPTION_VALUE_FLAGS_FALLBACK_codex="-c --config --enable --disable --remote --remote-auth-token-env -i --image -m --model --local-provider -p --profile -s --sandbox -C --cd --add-dir -a --ask-for-approval"
OPTION_VALUE_FLAGS_FALLBACK_pi="--provider --model --api-key --system-prompt --append-system-prompt --mode -n --name --models -t --tools -xt --exclude-tools --thinking -e --extension --skill --prompt-template --theme --use-theme --export --list-models --tui-mode"
OPTION_VALUE_FLAGS_FALLBACK_omp="--model --smol --slow --plan --prewalk-into --plan-yolo-into --provider --api-key --system-prompt --append-system-prompt --profile --alias --cwd --mode --config --session-dir --models --tools --thinking --hook -e --extension --skills --export --max-time --approval-mode --plugin-dir"
OPTION_VALUE_FLAGS_FALLBACK_grok="--model --effort --cwd"

# Discover options that accept a separate value from the top-level --help.
# Commander/clap-style help marks values as <...> or [...]; yargs-style help
# uses type annotations such as [string], [number], or [array], sometimes on a
# continuation line. Emit both long and short spellings so the argv filter can
# distinguish an option value from a positional prompt.
_discover_option_value_flags() {
	local tool="$1"
	local cache_var="_OPTION_VALUE_FLAGS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	local fallback_var="OPTION_VALUE_FLAGS_FALLBACK_${tool}"
	local fallback="${!fallback_var:-}"
	local help_out result=""
	help_out=$(_tool_help "$tool") || true
	if [ -n "$help_out" ]; then
		result=$(printf '%s\n' "$help_out" | awk '
			function flush() {
				if (head == "") return
				decl = head
				sub(/^[[:space:]]+/, "", decl)
				sub(/[[:space:]][[:space:]].*$/, "", decl)
				if (decl ~ /<[^>]+>/ ||
				    (decl ~ /\[[^]]+\]/ && decl !~ /\[boolean\]/) ||
				    entry ~ /\[(string|number|array)\]/) {
					print decl
				}
				head = ""
				entry = ""
			}
			/^[[:space:]]+(-[A-Za-z][A-Za-z0-9-]*[[:space:],]|--[A-Za-z][A-Za-z0-9-]*)/ {
				flush()
				head = $0
				entry = $0
				next
			}
			{ if (head != "") entry = entry "\n" $0 }
			END { flush() }
		' | grep -oE -- '--[A-Za-z][A-Za-z0-9-]*|(^|[[:space:],])-[A-Za-z][A-Za-z0-9-]*' |
			sed -E 's/^[[:space:],]+//') || true
	fi

	# Help output can be partial (and some supported options are hidden), so
	# supplement discovery with the pinned safe fallback just as session-flag
	# discovery does.
	result=$(printf '%s\n%s\n' "$result" "$fallback" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
	result="${result% }"
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Remove positional argv while retaining values belonging to known options.
# Once the first positional is seen, discard it and the entire remaining tail:
# a prompt can contain flag-looking words that must never become replayed flags.
_drop_positional_args() {
	local tool="$1" args="$2"
	# Bash 3.2 treats an empty array expansion as an unbound variable under
	# nounset.  Avoid constructing/iterating that array when there is no argv.
	case "$args" in
	*[![:space:]]*) ;;
	*) return 0 ;;
	esac
	local value_flags
	value_flags=" $(_discover_option_value_flags "$tool") "
	local variadic_flags=""
	[ "$tool" = "copilot" ] && variadic_flags=" $(_copilot_variadic_flags) "

	# Word-split with pathname expansion disabled: argv is data, so values such
	# as '*' must never expand against the save hook's working directory.
	local reglob=""
	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2206  # deliberate word-split of flattened argv
	local -a words=($args)
	[ -n "$reglob" ] && set +f

	local -a out=()
	local word flag="" expects_value=0 variadic=0
	for word in "${words[@]}"; do
		case "$word" in
		-*)
			out[${#out[@]}]="$word"
			flag="${word%%=*}"
			expects_value=0
			variadic=0
			case "$word" in
			*=*) ;;
			*)
				case "$value_flags" in
				*" $flag "*) expects_value=1 ;;
				esac
				case "$variadic_flags" in
				*" $flag "*) variadic=1 ;;
				esac
				;;
			esac
			;;
		*)
			if [ "$expects_value" -eq 1 ]; then
				out[${#out[@]}]="$word"
				if [ "$variadic" -eq 0 ]; then
					expects_value=0
					flag=""
				fi
			else
				break
			fi
			;;
		esac
	done

	[ "${#out[@]}" -gt 0 ] && echo "${out[*]}"
	return 0
}

# Discover session-identity flags from a tool's --help output.
# Matches long option names against a keyword pattern and emits lines of
# "long [short]" pairs (e.g. "--resume -r" or "--fork-session").
# Cached per tool in _SESSION_FLAGS_<tool> to avoid repeated --help calls.
_discover_session_flags() {
	local tool="$1" pattern="$2"
	local cache_var="_SESSION_FLAGS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		echo "$cached"
		return
	fi

	local help_out result=""
	local fallback_var="SESSION_FLAGS_FALLBACK_${tool}"
	local fallback="${!fallback_var:-}"
	help_out=$(_tool_help "$tool") || true
	if [ -n "$help_out" ]; then
		local line long short
		while IFS= read -r line; do
			long=$(echo "$line" | grep -oE -- '--[a-z][-a-z]*' | head -1) || continue
			echo "$long" | grep -qE "$pattern" || continue
			# Extract short flag: handles both "-X, --long" and "--long, -X" formats
			short=$(echo "$line" | grep -oE '(^|\s|,\s*)-[a-zA-Z](\s|,|$)' | grep -oE '\-[a-zA-Z]' | head -1 || true)
			result="${result}${long}${short:+ ${short}}
"
		done < <(echo "$help_out" | grep -E '^\s+(-[a-zA-Z],\s+)?--')
	fi

	if [ -n "$fallback" ]; then
		result="${result}${fallback}
"
	fi
	result=$(echo "$result" | sort -u | sed '/^$/d')
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Discover which session-identity subcommands a tool actually supports, by
# matching a pattern of candidate subcommand names against the tool's --help.
# Emits the confirmed subcommand names (one per line, in pattern order).
# Cached per tool in _SESSION_SUBCMDS_<tool> to avoid repeated --help calls:
# like _discover_session_flags this is called from extract_cli_args inside a
# $() subshell per pane, so the cache only pays off when warmed in main's shell.
_discover_session_subcmds() {
	local tool="$1" subcmd_pattern="$2"
	local cache_var="_SESSION_SUBCMDS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	# When --help is unavailable (tmux hooks may run with a limited PATH that
	# cannot resolve the binary), assume every candidate is supported so known
	# session subcommands are still stripped — matches prior behavior.
	local help_out subcmd result=""
	help_out=$(_tool_help "$tool") || true
	for subcmd in $(echo "$subcmd_pattern" | tr '|' ' '); do
		if [ -z "$help_out" ] || echo "$help_out" | grep -qw "$subcmd"; then
			result="${result}${subcmd}
"
		fi
	done
	result=$(echo "$result" | sed '/^$/d')
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Session-identity flag name patterns per tool.
# Matched against long option names from --help. Flag names are semantic
# (--resume always means resume), so new flags like --resume-from are
# auto-discovered without script changes.
SESSION_FLAG_PATTERN_claude='^--(resume|continue|session-id|fork-session|from-pr)$'
SESSION_FLAG_PATTERN_copilot='^--(connect|continue|interactive|name|prompt|resume|session-id)$'
SESSION_FLAG_PATTERN_opencode='^--session$'
SESSION_FLAG_PATTERN_pi='^--(session|resume|continue|fork)$'
SESSION_FLAG_PATTERN_omp='^--(session|resume|continue|fork)$'
SESSION_FLAG_PATTERN_grok='^--(resume|continue|session-id|fork-session)$'
# codex uses subcommands (resume, fork), not --flags — handled separately.
SESSION_SUBCMD_PATTERN_codex='resume|fork'
# Codex resume/fork have subcommand-specific picker flags that must also
# be stripped (they are not top-level options and break restore if kept).
SESSION_SUBCMD_FLAGS_codex='--last --all --include-non-interactive'

# Static fallbacks for when <tool> --help is unavailable (tmux hooks may
# run with a limited PATH that cannot resolve the binary).
SESSION_FLAGS_FALLBACK_claude="--continue -c
--fork-session
--from-pr
--resume -r
--session-id"
# --name is included deliberately: `copilot --name x --resume=<id>` is rejected
# outright ("cannot be used with"), so a named session must lose its name to be
# resumable at all.
SESSION_FLAGS_FALLBACK_copilot="--connect
--continue
--interactive -i
--name -n
--prompt -p
--resume -r
--session-id"
SESSION_FLAGS_FALLBACK_opencode="--session -s"
SESSION_FLAGS_FALLBACK_pi="--continue -c
--fork
--resume -r
--session"
SESSION_FLAGS_FALLBACK_omp="--continue -c
--fork
--resume -r
--session"
SESSION_FLAGS_FALLBACK_grok="--continue -c
--fork-session
--resume -r
--session-id -s"

# Every helper that parses --help must be warmed in main's shell so its cache
# survives the per-pane extract_cli_args command substitutions. The Copilot
# wrapper also retains the existing variadic-option discovery warmup.
_warm_cli_arg_helpers() {
	local tool="$1"
	_discover_option_value_flags "$tool" >/dev/null
	[ "$tool" = "copilot" ] && _copilot_variadic_flags >/dev/null
	return 0
}

SESSION_EXTRA_WARM_claude=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_copilot=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_opencode=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_codex=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_pi=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_omp=_warm_cli_arg_helpers
SESSION_EXTRA_WARM_grok=_warm_cli_arg_helpers

# Pre-warm session-identity discovery once per tool present in a tab-separated
# MATCHES blob (tool name in field 2). extract_cli_args runs in a $() subshell
# per pane and the discovery helpers cache into a shell var that does not
# survive the subshell, so without warming in main's shell `<tool> --help`
# re-runs for every assistant pane (e.g. 8 claude panes => 8 × `claude --help`).
# Driven off the SESSION_*_PATTERN_<tool> tables so every assistant is covered —
# flag-based (claude/opencode/pi) and subcommand-based (codex) alike — and new
# tools warm automatically once they gain a pattern, with no hardcoded list.
_warm_session_discovery() {
	local matches="$1"
	[ -n "$matches" ] || return 0
	local tool flag_pat sub_pat extra_warm
	while IFS= read -r tool; do
		# Skip blanks and names that are not valid shell identifier suffixes:
		# the indirect expansions below would otherwise abort under set -e.
		case "$tool" in
		'' | *[!A-Za-z0-9_]*) continue ;;
		esac
		# Populate the help cache in *this* shell. The discovery helpers below
		# read it through $(), where their own cache write would be discarded --
		# so without this direct call `<tool> --help` re-execs for every pane.
		_tool_help "$tool" >/dev/null

		flag_pat="SESSION_FLAG_PATTERN_${tool}"
		sub_pat="SESSION_SUBCMD_PATTERN_${tool}"
		if [ -n "${!flag_pat:-}" ]; then
			_discover_session_flags "$tool" "${!flag_pat}" >/dev/null
		fi
		if [ -n "${!sub_pat:-}" ]; then
			_discover_session_subcmds "$tool" "${!sub_pat}" >/dev/null
		fi
		# Per-tool extras that also parse --help and cache into a shell var.
		extra_warm="SESSION_EXTRA_WARM_${tool}"
		if [ -n "${!extra_warm:-}" ]; then
			"${!extra_warm}" "$tool" >/dev/null
		fi
	done < <(printf '%s\n' "$matches" | cut -f2 | sort -u)
	return 0
}

# --- CLI args extraction ---

# Extract CLI args from a process's full command line, stripping the binary
# name/path and tool-specific session/resume arguments.
#
# Usage: extract_cli_args <tool> <full_args_from_ps>
# Returns: replayable options and their recognized values as a single
# whitespace-normalized string. Positional arguments are omitted.
#
# Session-identity flags are discovered dynamically from <tool> --help,
# matched by name pattern. This keeps stripping in sync with the installed
# tool version without manual flag list maintenance.
extract_cli_args() {
	local tool="$1" raw_args="$2" pid="${3:-}"
	local _COPILOT_DROPPED_PERMISSION=0

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

	# `ps` flattens argv and loses the quoting boundary around a multi-word
	# Copilot --prompt/-p and --interactive/-i values. Token-wise stripping
	# could therefore replay trailing prompt words as positional args and make
	# resume fail. Keep flags before the initial prompt, but drop it and
	# everything after it.
	if [ "$tool" = "copilot" ]; then
		# Prefer exact argv where the kernel still has it; the heuristics below
		# only run when boundaries are genuinely unrecoverable (macOS/BSD).
		local exact_args="" exact_rc=0
		exact_args=$(_copilot_args_from_exact_argv "$pid") || exact_rc=$?
		local have_exact=0
		if [ "$exact_rc" -ne 1 ]; then
			have_exact=1
			args="$exact_args"
			[ "$exact_rc" -eq 9 ] && _COPILOT_DROPPED_PERMISSION=1
		fi
		args=$(echo "$args" | sed -E \
			-e 's/(^| )--prompt([= ].*)?$//' \
			-e 's/(^| )-p([= ].*)?$//' \
			-e 's/(^| )--interactive([= ].*)?$//' \
			-e 's/(^| )-i([= ].*)?$//')
		# Before the session-flag pass, while each value is still adjacent to the
		# option it belongs to: the strippers below consume only one token, which
		# would leave the tail of a flattened multi-word value stranded as a
		# positional.
		if [ "$have_exact" -eq 0 ]; then
			local flat_rc=0
			args=$(_copilot_drop_flattened_values "$args") || flat_rc=$?
			[ "$flat_rc" -eq 9 ] && _COPILOT_DROPPED_PERMISSION=1
		fi
		# Restore always resumes interactively, and Copilot refuses --attachment
		# there ("only supported in non-interactive prompt mode"). The prompt
		# truncation above misses it whenever it was written *before* the prompt,
		# so drop it explicitly wherever it sat. Verified against 1.0.78; the
		# other non-interactive-flavored flags (--silent, --share, --share-gist,
		# --enable-memory) resume without complaint and are left alone.
		args=$(_strip_long_opt '--attachment' "$args")
		# Copilot hides --worktree/-w and --cloud from --help, so the discovery
		# pattern can never learn them, yet both are refused alongside --resume
		# ("cannot be used with"). Strip them explicitly. Verified on 1.0.78.
		args=$(_strip_long_opt '--worktree' "$args")
		args=$(_strip_short_opt '-w' "$args")
		args=$(_strip_bool_opt '--cloud' "$args")
		if [ "$_COPILOT_DROPPED_PERMISSION" -eq 1 ]; then
			# Once a restriction is lost, no remaining flag set is provably
			# equivalent: granular grants, MCP enablement, path allowances, and
			# future permission flags can all interact with it. Replay no flags
			# and let bare resume return to Copilot's prompting defaults.
			args=""
		fi
	fi

	# Strip tool-specific session/resume flags.
	local pattern_var="SESSION_FLAG_PATTERN_${tool}"
	local pattern="${!pattern_var:-}"
	local subcmd_var="SESSION_SUBCMD_PATTERN_${tool}"
	local subcmd_pattern="${!subcmd_var:-}"

	if [ -n "$pattern" ]; then
		local flags line long short
		flags=$(_discover_session_flags "$tool" "$pattern")
		if [ "$flags" != "-" ] && [ -n "$flags" ]; then
			while IFS= read -r line; do
				long="${line%% *}"
				short="${line#"$long"}"
				short="${short# }"
				args=$(_strip_long_opt "$long" "$args")
				[ -n "$short" ] && args=$(_strip_short_opt "$short" "$args")
			done < <(printf '%s\n' "$flags")
		fi
	fi

	if [ -n "$subcmd_pattern" ]; then
		local subcmd
		local -a confirmed_subcmds=()
		while IFS= read -r subcmd; do
			[ -n "$subcmd" ] && confirmed_subcmds+=("$subcmd")
		done < <(_discover_session_subcmds "$tool" "$subcmd_pattern")
		if [ "${#confirmed_subcmds[@]}" -gt 0 ]; then
			args=$(_strip_subcmds "$args" "${confirmed_subcmds[@]}")
			# Strip subcommand-specific picker flags (e.g. codex resume --last)
			local subcmd_flags_var="SESSION_SUBCMD_FLAGS_${tool}"
			local subcmd_flags="${!subcmd_flags_var:-}"
			local flag
			for flag in $subcmd_flags; do
				args=$(_strip_bool_opt "$flag" "$args")
			done
		fi
	fi

	# A remaining positional is an initial prompt (or, for OpenCode, a project
	# path already represented by pane cwd). Never replay it into a resumed
	# conversation. Preserve recognized separate option values such as
	# `--model sonnet`; a boolean option followed by a prompt is not mistaken for
	# a value because option arity comes from --help rather than adjacency.
	args=$(_drop_positional_args "$tool" "$args")

	# Normalize whitespace: collapse multiple spaces, trim leading/trailing
	echo "$args" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

# Resolve all detected assistant candidates for one pane and emit at most one
# session entry (first resolvable candidate in BFS order).
#
# Defers ambiguous or potentially stale fallbacks:
#   pass 1: PID-specific native state only
#   pass 2: OpenCode DB fallback and Copilot launcher-argv fallback
resolve_pane_candidates() {
	local pane_target="$1"
	local pane_cwd="$2"
	local pane_tty="$3"
	local pane_candidates="$4"
	local us="$5"
	local has_assoc_cache="$6"
	local state_cache_file="$7"
	local parts_file="$8"
	# The parts pane_target is composed from. Saved separately so restore never
	# has to parse a target whose session name may itself contain ':' or '.'.
	local pane_session="${9:-}"
	local pane_window="${10:-}"
	local pane_pane_index="${11:-}"

	local resolved=0 first_tool="" first_pid="" first_args=""
	for pass in 1 2; do
		[ "$resolved" -eq 1 ] && break
		local allow_deferred_fallback=0
		[ "$pass" -eq 2 ] && allow_deferred_fallback=1
		while IFS="$us" read -r cand_tool cand_pid cand_args; do
			[ -z "$cand_tool" ] && continue
			if [ -z "$first_tool" ]; then
				first_tool="$cand_tool"
				first_pid="$cand_pid"
				first_args="$cand_args"
			fi

			# Pass 2 is only for fallbacks that can misidentify a live session:
			# OpenCode's cwd-scoped DB and Copilot's possibly stale loader argv.
			if [ "$pass" -eq 2 ]; then
				case "$cand_tool" in
				opencode | copilot) ;;
				*) continue ;;
				esac
			fi

			local cached="" cached_sid="" cached_model="" cached_env="null"
			if [ "$has_assoc_cache" -eq 1 ]; then
				cached="${STATE_CACHE[$cand_pid]:-}"
			elif [ -s "$state_cache_file" ]; then
				cached=$(awk -F"$us" -v p="$cand_pid" '$1 == p {for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?FS:""); print ""; exit}' "$state_cache_file")
			fi
			if [ -n "$cached" ]; then
				cached_sid="${cached%%"$us"*}"
				local _rest="${cached#*"$us"}"
				cached_model="${_rest%%"$us"*}"
				cached_env="${_rest#*"$us"}"
				[ -z "$cached_env" ] && cached_env="null"
			fi

			local session_id="" copilot_state_dir=""
			if [ "$cand_tool" = "copilot" ]; then
				copilot_state_dir=$(copilot_session_state_dir "$cand_args" "$cand_pid")
			fi
			case "$cand_tool" in
			claude)
				session_id="$cached_sid"
				# Keep legacy fallback behavior when cache misses (state file + --resume).
				[ -z "$session_id" ] && session_id=$(get_claude_session "$cand_pid" "$cand_args" || true)
				;;
			copilot) session_id=$(get_copilot_session "$cand_pid" "$cand_args" "$allow_deferred_fallback" "$copilot_state_dir" || true) ;;
			opencode)
				session_id="$cached_sid"
				[ -z "$session_id" ] && session_id=$(get_opencode_session "$cand_pid" "$cand_args" "$pane_cwd" "$allow_deferred_fallback" || true)
				;;
			codex) session_id=$(get_codex_session "$cand_pid" "$cand_args" "$pane_cwd" || true) ;;
			pi) session_id=$(get_pi_session "$cand_pid" "$cand_args" "$pane_cwd" || true) ;;
			omp) session_id=$(get_omp_session "$cand_pid" "$cand_args" "$pane_cwd" "$pane_tty" || true) ;;
			grok) session_id=$(get_grok_session "$cand_pid" "$cand_args" || true) ;;
			esac

			if [ -n "$session_id" ]; then
				local cli_args model="" env_json="null" state_file="" copilot_home=""
				cli_args=$(extract_cli_args "$cand_tool" "$cand_args" "$cand_pid")
				model="$cached_model"
				env_json="$cached_env"
				if [ "$cand_tool" = "copilot" ]; then
					copilot_home="${copilot_state_dir%/session-state}"
				fi

				# If cache wasn't available, fall back to direct state-file enrichment.
				case "$cand_tool" in
				claude) state_file="$STATE_DIR/claude-${cand_pid}.json" ;;
				opencode) state_file="$STATE_DIR/opencode-${cand_pid}.json" ;;
				esac
				if [ -n "$state_file" ] && [ -f "$state_file" ]; then
					[ -z "$model" ] && model=$(jq -r '.model // empty' "$state_file" 2>/dev/null || true)
					if [ "$env_json" = "null" ]; then
						env_json=$(jq '.env // null' "$state_file" 2>/dev/null || echo "null")
					fi
				fi
				env_json=$(merge_process_env "$cand_pid" "$env_json")

				# Fallback: parse --model from CLI args if not in state file.
				# Regex stored in variable for bash 3.2 compat (inline capture groups fail).
				local _model_re='--model[= ]([^ ]+)'
				if [ -z "$model" ] && [[ "$cand_args" =~ $_model_re ]]; then
					model="${BASH_REMATCH[1]}"
				fi

				# Write TSV for batch JSON conversion (replaces per-entry jq -n).
				# New columns are appended so the existing indices stay put.
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$pane_target" "$cand_tool" "$session_id" "$pane_cwd" "$cand_pid" "$model" "$cli_args" "$env_json" "$copilot_home" \
					"$pane_session" "$pane_window" "$pane_pane_index" >>"$parts_file"

				case "$cand_tool" in
				codex) register_codex_session_id "$session_id" ;;
				pi) register_pi_session_id "$session_id" ;;
				omp) register_omp_session_id "$session_id" ;;
				esac
				resolved=1
				break
			fi
		done < <(printf '%s\n' "$pane_candidates")
	done

	if [ "$resolved" -eq 0 ] && [ -n "$first_tool" ]; then
		if ! handle_sessionless_relaunch "$pane_target" "$first_tool" "$first_pid" "$first_args" "$pane_cwd" 1; then
			UNRESOLVED_PANES=$((UNRESOLVED_PANES + 1))
		fi
	fi
}

# --- Watchdog (defense-in-depth) ---

# Print root plus all of its descendant PIDs, one per line, from a fresh ps
# snapshot. Portable across macOS and Linux (no pgrep/pkill/setsid needed).
# The fixpoint loop over the parent map handles arbitrary tree depth regardless
# of the order ps lists processes in.
descendant_pids() {
	local root="$1"
	ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root" '
		{ pid[NR] = $1; parent[$1] = $2 }
		END {
			seen[root] = 1
			changed = 1
			while (changed) {
				changed = 0
				for (i = 1; i <= NR; i++) {
					p = pid[i]
					if (!(p in seen) && (parent[p] in seen)) {
						seen[p] = 1
						changed = 1
					}
				}
			}
			for (p in seen) print p
		}'
}

# Send signal $1 to each remaining PID in $2.. (best-effort; already-exited
# PIDs are ignored). Takes an explicit list so a caller can capture a PID set
# once and signal that exact set later, even if the tree has since changed.
signal_pids() {
	local sig="$1" pid
	shift
	for pid in "$@"; do
		kill "-$sig" "$pid" 2>/dev/null || true
	done
}

# Space-separated descendants of $root, excluding $root itself and $skip (the
# watchdog's own PID).
# shellcheck disable=SC2178,SC2128  # out is a plain string, not an array
victim_pids() {
	local root="$1" skip="$2" pid out=""
	for pid in $(descendant_pids "$root"); do
		[ "$pid" = "$root" ] && continue
		[ "$pid" = "$skip" ] && continue
		out="$out $pid"
	done
	printf '%s' "$out"
}

# Reap every descendant of $root once (NOT $root, never $skip). Retained as a
# tested one-shot utility; save_watchdog uses the snapshot-based logic below.
reap_descendants() {
	local root="$1" skip="$2" sig="$3"
	# shellcheck disable=SC2086,SC2046  # deliberate word-split of PID list
	signal_pids "$sig" $(victim_pids "$root" "$skip")
}

# Background watchdog: a bounded hard deadline for the whole save hook. After
# SAVE_TIMEOUT seconds it SIGTERMs the current worker subprocesses so a wedged
# command substitution unblocks and main can finish cleanly. If the hook is
# still alive after a short grace period it escalates to SIGKILL — over both the
# original victim set (covering children reparented away by the TERM) and a
# fresh snapshot (covering workers spawned since) — and finally kills main
# itself, so the hook can never run past the deadline regardless of what it does
# after the first reap.
save_watchdog() {
	local target="$1" selffile="$2" firedfile="$3" self="" victims fresh
	# A signal-kill (normal-exit cleanup) terminates this subshell outright and
	# skips the reap. `|| exit 0` only guards a non-signal early return.
	sleep "$SAVE_TIMEOUT" || exit 0

	# Mark ourselves "fired". From here on, stop_save_watchdog will NOT cancel
	# us: once the deadline is reached we must run the escalation to completion,
	# even if killing a worker lets main unblock and exit during the grace below.
	# Otherwise a TERM-surviving grandchild reparented off that worker would be
	# stranded when main's exit cancelled us mid-grace.
	echo fired >"$firedfile" 2>/dev/null || true

	# Learn our own PID (written by main after fork) so we never reap ourselves.
	# bash 3.2 has no $BASHPID, and a subshell's $$ is the parent's, so main
	# hands us our PID through this file instead.
	[ -f "$selffile" ] && self=$(cat "$selffile" 2>/dev/null || true)

	# Round 1: TERM the current workers so a merely-wedged save can unblock and
	# finish cleanly during the grace period.
	victims=$(victim_pids "$target" "$self")
	# shellcheck disable=SC2086
	signal_pids TERM $victims
	sleep 2 || true

	# Escalate the captured victims to SIGKILL UNCONDITIONALLY — a TERM survivor
	# is a leak whether or not main recovered, and it may have been reparented
	# away from main's tree (so it is no longer reachable from $target). Then, if
	# the hook itself is still alive, also KILL any workers spawned since and the
	# hook process, enforcing the hard deadline.
	# shellcheck disable=SC2086
	signal_pids KILL $victims
	if kill -0 "$target" 2>/dev/null; then
		fresh=$(victim_pids "$target" "$self")
		# shellcheck disable=SC2086
		signal_pids KILL $fresh
		kill -KILL "$target" 2>/dev/null || true
	fi

	# Report last, and to STDERR only — never to LOG_FILE. When the hang is a
	# stalled RESURRECT_DIR filesystem, a file write here would block this
	# (now orphaned) watchdog forever, and one would pile up per save cycle —
	# exactly the process accumulation the deadline exists to prevent. stderr is
	# the hook's own descriptor, not the stalled filesystem, so it can't block on
	# it; tmux-resurrect surfaces it wherever it captures hook output.
	echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] save hook exceeded ${SAVE_TIMEOUT}s; terminated stuck save (watchdog)" >&2
}

# Stop the watchdog on normal completion. If it has already fired (reached the
# deadline), leave it alone: it is escalating and must finish, and it will exit
# on its own within the grace window. Otherwise snapshot the watchdog subtree
# and signal the captured PIDs, so a sleep child reparented between the two
# steps is still killed by PID (no orphans).
stop_save_watchdog() {
	[ -n "${WATCHDOG_PID:-}" ] || return 0
	if [ -s "${WATCHDOG_FIRED_FILE:-/nonexistent}" ]; then
		WATCHDOG_PID=""
		return 0
	fi
	# shellcheck disable=SC2046
	signal_pids TERM $(descendant_pids "$WATCHDOG_PID")
	WATCHDOG_PID=""
}

# --- Main ---

main() {
	# Reset per-run: the script is sourceable, so main() can be entered more
	# than once in one shell and a stale count would carry over.
	UNRESOLVED_PANES=0
	PS_FILE=$(mktemp)
	PANE_FILE=$(mktemp)
	PARTS_FILE=$(mktemp)
	RELAUNCH_PARTS_FILE=$(mktemp)
	STATE_CACHE_FILE=$(mktemp)
	WATCHDOG_PID=""
	WATCHDOG_SELF_FILE=""
	WATCHDOG_FIRED_FILE=""
	SESSIONS_TMP=""
	OUTPUT_TMP=""
	# stop_save_watchdog MUST run before the rm: it reads WATCHDOG_FIRED_FILE to
	# decide whether the watchdog has already fired (and so must not be cancelled).
	# Deleting that file first would make the fired-check always fail, cancelling a
	# mid-escalation watchdog and defeating the whole grandchild-leak guarantee.
	trap 'stop_save_watchdog; rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE" "$RELAUNCH_PARTS_FILE" "$STATE_CACHE_FILE" "${WATCHDOG_SELF_FILE:-}" "${WATCHDOG_FIRED_FILE:-}" "${RELAUNCH_LEDGER_TMP:-}" "${SESSIONS_TMP:-}" "${OUTPUT_TMP:-}"' EXIT INT TERM

	# Arm the watchdog (unless disabled with a 0/invalid timeout).
	if [ "$SAVE_TIMEOUT" -gt 0 ]; then
		WATCHDOG_SELF_FILE=$(mktemp)
		WATCHDOG_FIRED_FILE=$(mktemp)  # empty until the watchdog reaches the deadline
		# Detach the watchdog's stdout (>/dev/null) so, if it lingers after firing,
		# it never holds the hook's stdout open and delay the caller. Its stderr is
		# kept for the timeout diagnostic.
		save_watchdog "$$" "$WATCHDOG_SELF_FILE" "$WATCHDOG_FIRED_FILE" >/dev/null &
		WATCHDOG_PID=$!
		# Hand the watchdog its own PID (so it can exclude itself when reaping),
		# then drop it from the job table so a normal-exit kill doesn't emit a
		# "Terminated" job notification onto the hook's stderr.
		echo "$WATCHDOG_PID" >"$WATCHDOG_SELF_FILE"
		disown "$WATCHDOG_PID" 2>/dev/null || true
	fi

	# Timestamp for the JSON output envelope
	local SAVE_TS
	SAVE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Snapshot process table and pane info to temp files (each read once)
	ps -eo pid=,ppid=,args= >"$PS_FILE" 2>/dev/null
	if [ ! -s "$PS_FILE" ]; then
		log "ps snapshot failed or empty, skipping save"
		rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE" "$RELAUNCH_PARTS_FILE"
		return 1
	fi
	# Two tagged records per pane, both ending in the one field that may itself
	# contain the '|' delimiter (the session name / the pane path). Everything
	# before it is '|'-free — a pane id, a pid, numeric indices, a /dev/... tty —
	# so awk can peel those off the front by position and take the rest verbatim.
	# Emitting the two free-form fields on separate records is what keeps them
	# from shifting each other.
	#
	# A control-character delimiter would be simpler but is not portable: tmux
	# < 3.7 rewrites those in -F output, and differently per version (3.4 emits
	# the octal escape, 3.5 the hex escape, 3.6 an underscore).
	#
	# The records join on #{pane_id}, not #{pane_pid}: it is '%' plus digits (so
	# still delimiter-free), and tmux never reuses one within a server, whereas
	# the kernel can hand a dead pane's pid to a new one between the two calls
	# and silently pair one pane's metadata with another's cwd.
	#
	# The calls are a moment apart either way. A pane that dies in between has a
	# P record but no C record, so it saves with an empty cwd; one created in
	# between has a C record but no P record, so it is not saved at all. Both are
	# bounded and self-correcting on the next save — restore skips the `cd` in
	# the first case, and the pane had no assistant to save in the second.
	{
		tmux list-panes -a -F "P|#{pane_id}|#{pane_pid}|#{window_index}|#{pane_index}|#{pane_tty}|#{session_name}"
		tmux list-panes -a -F "C|#{pane_id}|#{pane_current_path}"
	} >"$PANE_FILE"

	# --- Single awk pass: detect assistant tools across ALL pane process trees ---
	# Replaces ~200 separate echo|awk pipe invocations with one pass.
	# Reads pane list + ps snapshot, builds process tree in memory,
	# BFS-walks descendants for each pane PID, detects tools.
	# Output (tab-delimited):
	#   target\ttool\ttool_pid\ttool_args\tcwd\tpane_tty\tsession\twindow\tindex
	# The session/window/index columns are appended rather than inserted so that
	# `cut -f2` in _warm_session_discovery() still selects the tool.
	# NOTE: emit all candidates per pane (pane PID + descendants) in BFS order.
	# The shell pass below preserves legacy two-pass OpenCode behavior:
	# 1) PID-specific only, then 2) DB fallback.
	local MATCHES
	MATCHES=$(awk \
		-f "$SCRIPT_DIR/lib-detect.awk" \
		-f "$SCRIPT_DIR/save-assistant-sessions.awk" \
		"$PANE_FILE" "$PS_FILE")

	rm -f "$PS_FILE" "$PANE_FILE"

	# Both must run before the cache glob below and before any get_*_session call,
	# so the pass sees the migrated files and not the reaped ones.
	migrate_legacy_state_files
	reap_stale_state_files

	# --- Pre-cache all state files in one jq call (requires jq 1.7+) ---
	# Replaces ~58 per-file jq invocations with one jq + bash associative array.
	# Uses jq 1.7+ input_filename to map filenames to PIDs.
	# Keys: PID. Values: session_id<US>model<US>env_json
	# Delimiter: US (unit separator \x1f) instead of TAB because bash read
	# collapses consecutive whitespace IFS characters (including TAB),
	# silently merging empty fields with the next non-empty field.
	#
	# Tradeoff: jq aborts at the first parse error (jqlang/jq#1942), so a
	# corrupt state file drops cache entries for files listed after it. Those
	# sessions fall through to per-session extraction (--resume args, per-file
	# jq in get_*_session) and still save correctly — just without the batch
	# speedup. Corrupt files are rare (hooks write atomically) and transient
	# (overwritten on next hook invocation). Pre-validating with `jq empty`
	# per file costs ~190ms (60 files), which negates the entire batch gain.
	local US=$'\x1f'
	local HAS_ASSOC_CACHE=0
	# Feature-detect jq 1.7+ (input_filename support). Use echo+pipe so jq
	# has valid JSON input — /dev/null has no content and causes a parse error.
	if echo '{}' | jq 'input_filename' >/dev/null 2>&1; then
		local state_files=()
		for _f in "$STATE_DIR"/claude-*.json "$STATE_DIR"/opencode-*.json; do
			[ -f "$_f" ] && state_files+=("$_f")
		done
		if [ ${#state_files[@]} -gt 0 ]; then
			jq -r '[
					(input_filename | split("/") | .[-1] | split("-")[1:] | join("-") | rtrimstr(".json")),
					(.session_id // ""),
					(.model // ""),
					((.env // null) | tojson)
				] | join("\u001f")' "${state_files[@]}" 2>/dev/null >"$STATE_CACHE_FILE" || true

			if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [ -s "$STATE_CACHE_FILE" ]; then
				HAS_ASSOC_CACHE=1
				# shellcheck disable=SC2034
				declare -A STATE_CACHE
				while IFS="$US" read -r _pid _sid _model _env; do
					STATE_CACHE["$_pid"]="$_sid$US$_model$US$_env"
				done <"$STATE_CACHE_FILE"
			elif [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [ -s "$STATE_CACHE_FILE" ]; then
				log "bash < 4 detected; associative cache disabled (falling through to direct state-file reads)"
			fi
		fi
	else
		log "jq < 1.7 detected; state file cache disabled (falling through to per-file reads)"
	fi

	# Pre-warm session-identity discovery so the per-pane $() subshells inherit
	# a populated cache instead of each re-running `<tool> --help`. Warming must
	# happen here in main's shell — the subshells cannot write back into it.
	# Only tools present in MATCHES are warmed (see _warm_session_discovery).
	_warm_session_discovery "$MATCHES"

	# Process only matched panes (those with a detected tool)
	if [ -n "$MATCHES" ]; then
		local current_target="" current_cwd="" current_tty="" pane_candidates=""
		local current_sess="" current_win="" current_idx=""
		while IFS=$'\t' read -r target tool cpid cargs cwd tty sess win idx; do
			[ -z "$target" ] && continue

			# If pane changed, process the previous pane's candidate list.
			if [ -n "$current_target" ] && [ "$target" != "$current_target" ]; then
				resolve_pane_candidates "$current_target" "$current_cwd" "$current_tty" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE" "$current_sess" "$current_win" "$current_idx"
				pane_candidates=""
			fi

			current_target="$target"
			current_cwd="$cwd"
			current_tty="$tty"
			current_sess="$sess"
			current_win="$win"
			current_idx="$idx"
			# Candidate tuples are US-delimited; a literal \x1f inside process args
			# would break parsing, but this is practically unlikely for CLI argv.
			pane_candidates="${pane_candidates}${tool}${US}${cpid}${US}${cargs}"$'\n'
		done < <(printf '%s\n' "$MATCHES")

		# Process final pane candidate list.
		if [ -n "$current_target" ] && [ -n "$pane_candidates" ]; then
			resolve_pane_candidates "$current_target" "$current_cwd" "$current_tty" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE" "$current_sess" "$current_win" "$current_idx"
		fi
	fi

	# Keep the established session TSV untouched, then convert the separate
	# five-field relaunch TSV and attach it as an optional sibling key. Older
	# restore scripts read only .sessions and safely ignore .relaunch.
	# Write to a temp file and rename into place so a failed or watchdog-killed jq
	# leaves the previous valid sidecar intact (a bare `>"$OUTPUT_FILE"` truncates
	# it before jq runs, which would lose all saved sessions on a timeout).
	local count=0 relaunch_count=0
	SESSIONS_TMP=$(mktemp "${OUTPUT_FILE}.sessions.tmp.XXXXXX")
	OUTPUT_TMP=$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")
	if ! jq -Rs --arg ts "$SAVE_TS" '
			split("\n") | map(select(length > 0) | split("\t") |
			{pane:.[0], tool:.[1], session_id:.[2], cwd:.[3], pid:.[4], model:.[5], cli_args:.[6],
			 env:(.[7] // "null" | try fromjson catch null), copilot_home:(.[8] // ""),
			 session_name:(.[9] // ""), window_index:(.[10] // ""), pane_index:(.[11] // "")})
			| {timestamp: $ts, sessions: .}
		' "$PARTS_FILE" >"$SESSIONS_TMP"; then
		rm -f "$SESSIONS_TMP" "$OUTPUT_TMP"
		log "warning: failed to serialize sessions; keeping previous $OUTPUT_FILE"
		return 1
	fi
	if ! jq -Rs --slurpfile envelope "$SESSIONS_TMP" '
		split("\n") | map(select(length > 0) | split("\t") |
		{pane:.[0], tool:.[1], cwd:.[2], pid:.[3], cmd:.[4]}) as $relaunch |
		$envelope[0] + {relaunch: $relaunch}
	' "$RELAUNCH_PARTS_FILE" >"$OUTPUT_TMP"; then
		rm -f "$SESSIONS_TMP" "$OUTPUT_TMP"
		log "warning: failed to serialize relaunch entries; keeping previous $OUTPUT_FILE"
		return 1
	fi
	rm -f "$SESSIONS_TMP"
	mv -f "$OUTPUT_TMP" "$OUTPUT_FILE"
	SESSIONS_TMP=""
	OUTPUT_TMP=""
	count=$(jq '.sessions | length' "$OUTPUT_FILE")
	relaunch_count=$(jq '.relaunch | length' "$OUTPUT_FILE")

	if [ "$UNRESOLVED_PANES" -gt 0 ]; then
		log "saved $count assistant session(s) to $OUTPUT_FILE ($UNRESOLVED_PANES detected but unresolved)"
	else
		log "saved $count assistant session(s) to $OUTPUT_FILE"
	fi
	[ "$relaunch_count" -gt 0 ] && log "saved $relaunch_count vouched assistant relaunch command(s)"

	# Strip captured pane contents for assistant panes so tmux-resurrect
	# won't restore stale TUI output that the post-restore hook would
	# immediately replace. Non-assistant pane contents are preserved.
	if [ $((count + relaunch_count)) -gt 0 ]; then
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

	# Collect pane targets from saved sessions and vouched relaunches.
	local panes
	panes=$(jq -r '(.sessions // [])[]?.pane, (.relaunch // [])[]?.pane' "$OUTPUT_FILE" 2>/dev/null) || return 0
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
	done < <(printf '%s\n' "$panes")

	if [ "$removed" -gt 0 ]; then
		local archive_tmp
		archive_tmp=$(mktemp "${archive}.tmp.XXXXXX") || archive_tmp=""
		if [ -n "$archive_tmp" ] && tar cf - -C "$tmpdir" ./pane_contents/ | gzip >"$archive_tmp" 2>/dev/null; then
			mv "$archive_tmp" "$archive"
			log "stripped pane contents for $removed assistant pane(s)"
		else
			log "warning: failed to repack pane_contents archive"
			[ -z "$archive_tmp" ] || rm -f "$archive_tmp"
		fi
	fi

	rm -rf "$tmpdir"
}

# Retained for backward compatibility — main() no longer calls this directly
# (batched processing replaced per-pane emit), but external scripts or tests
# may source this file and call emit_session().
emit_session() {
	local target="$1" tool="$2" cpid="$3" cargs="$4" cwd="$5"
	local allow_opencode_db="${6:-1}"
	local log_missing="${7:-1}"
	local session_id="" copilot_state_dir=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$cpid" "$cargs" || true) ;;
	copilot)
		copilot_state_dir=$(copilot_session_state_dir "$cargs" "$cpid")
		session_id=$(get_copilot_session "$cpid" "$cargs" 1 "$copilot_state_dir" || true)
		;;
	opencode) session_id=$(get_opencode_session "$cpid" "$cargs" "$cwd" "$allow_opencode_db" || true) ;;
	codex) session_id=$(get_codex_session "$cpid" "$cargs" "$cwd" || true) ;;
	pi) session_id=$(get_pi_session "$cpid" "$cargs" "$cwd" || true) ;;
	omp) session_id=$(get_omp_session "$cpid" "$cargs" "$cwd" "" || true) ;;
	grok) session_id=$(get_grok_session "$cpid" "$cargs" || true) ;;
	esac

	if [ -n "$session_id" ]; then
		# Extract CLI args (flags without binary name and session/resume args)
		local cli_args copilot_home=""
		cli_args=$(extract_cli_args "$tool" "$cargs" "$cpid")
		if [ "$tool" = "copilot" ]; then
			copilot_home="${copilot_state_dir%/session-state}"
		fi

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
		env_json=$(merge_process_env "$cpid" "$env_json")

		# Fallback: parse --model from CLI args if not in state file
		if [ -z "$model" ]; then
			model=$(echo "$cargs" | sed -n 's/.*--model[= ] *\([^ ]*\).*/\1/p')
		fi

		# This shim only receives the composed target, so recover the parts from
		# it. Splitting from the right is exact — see split_pane_target().
		PANE_TARGET_SESSION="" PANE_TARGET_WINDOW="" PANE_TARGET_INDEX=""
		split_pane_target "$target" || true

		jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg pid "$cpid" \
			--arg model "$model" \
			--arg cli_args "$cli_args" \
			--arg copilot_home "$copilot_home" \
			--arg session_name "$PANE_TARGET_SESSION" \
			--arg window_index "$PANE_TARGET_WINDOW" \
			--arg pane_index "$PANE_TARGET_INDEX" \
			--argjson env "${env_json:-null}" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid, model: $model, cli_args: $cli_args, env: $env, copilot_home: $copilot_home, session_name: $session_name, window_index: $window_index, pane_index: $pane_index}' >>"$PARTS_FILE"
		case "$tool" in
		codex) register_codex_session_id "$session_id" ;;
		pi) register_pi_session_id "$session_id" ;;
		omp) register_omp_session_id "$session_id" ;;
		esac
		return 0
	else
		handle_sessionless_relaunch "$target" "$tool" "$cpid" "$cargs" "$cwd" "$log_missing"
	fi
}

# Allow sourcing this script without executing main (for unit tests).
# When sourced, only functions and variables are defined.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
