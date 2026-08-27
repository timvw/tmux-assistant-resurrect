#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

# Source shared library (detect_tool, pane_has_assistant, posix_quote,
# split_pane_target, resolve_tmux_pane_id)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

# Follow tmux-resurrect's own save-dir resolution (resurrect_data_dir in
# lib-detect.sh) so we read the sidecar from wherever resurrect saved it.
RESURRECT_DIR="$(resurrect_data_dir)"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

# The log contains session ids and reconstructed CLI arguments/environment.
# Keep newly-created logs private and never reopen the published path for
# writing: a retained descriptor prevents a later symlink swap from redirecting
# log output.
umask 077
LOG_ENABLED=0
log_previous=""
log_previous_copied=0
if [ -e "$LOG_FILE" ] || [ -L "$LOG_FILE" ]; then
	if [ -L "$LOG_FILE" ]; then
		printf '%s\n' "tmux-assistant-resurrect: refusing symlinked restore log: $LOG_FILE" >&2
	elif [ ! -f "$LOG_FILE" ]; then
		printf '%s\n' "tmux-assistant-resurrect: refusing non-regular restore log: $LOG_FILE" >&2
	else
		log_previous=$(mktemp "${LOG_FILE}.rotate.XXXXXX" 2>/dev/null || true)
		if [ -z "$log_previous" ] || ! mv "$LOG_FILE" "$log_previous" 2>/dev/null; then
			printf '%s\n' "tmux-assistant-resurrect: cannot rotate restore log, disabling file logging: $LOG_FILE" >&2
			[ -z "$log_previous" ] || rm -f "$log_previous"
			log_previous=""
		fi
	fi
fi

if { [ ! -e "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ]; } &&
	{ [ -z "$log_previous" ] || { [ -f "$log_previous" ] && [ ! -L "$log_previous" ]; }; }; then
	log_had_noclobber=0
	case "$-" in *C*) log_had_noclobber=1 ;; esac
	set -C
	if exec 9>"$LOG_FILE"; then
		LOG_ENABLED=1
	fi
	[ "$log_had_noclobber" -eq 1 ] || set +C
	if [ "$LOG_ENABLED" -eq 1 ] && [ -n "$log_previous" ]; then
		if tail -n 500 "$log_previous" >&9 2>/dev/null; then
			log_previous_copied=1
		fi
	fi
fi

if [ -n "$log_previous" ]; then
	if [ "$LOG_ENABLED" -eq 1 ] && [ "$log_previous_copied" -eq 1 ]; then
		rm -f "$log_previous"
	else
		printf '%s\n' "tmux-assistant-resurrect: previous restore log retained at $log_previous" >&2
	fi
fi
if [ "$LOG_ENABLED" -ne 1 ] && [ ! -e "$LOG_FILE" ]; then
	printf '%s\n' "tmux-assistant-resurrect: cannot securely open restore log, disabling file logging: $LOG_FILE" >&2
fi
unset log_previous log_previous_copied log_had_noclobber

log() {
	local msg
	msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	# Sidecar values may contain control characters. Keep one event per physical
	# line and prevent a corrupt cache from forging log entries or emitting an
	# escape sequence into the restore hook's terminal.
	msg="${msg//$'\r'/\\r}"
	msg="${msg//$'\n'/\\n}"
	msg="${msg//$'\033'/\\e}"
	printf '%s\n' "$msg" >&2
	if [ "$LOG_ENABLED" -eq 1 ]; then
		if ! printf '%s\n' "$msg" >&9 2>/dev/null; then
			LOG_ENABLED=0
			printf '%s\n' "tmux-assistant-resurrect: cannot write restore log, disabling file logging: $LOG_FILE" >&2
		fi
	fi
}

if [ ! -f "$INPUT_FILE" ]; then
	log "no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read resumable sessions and vouched session-less relaunches as one tagged
# stream. The sibling-key schema keeps both upgrade directions safe: old
# restores ignore .relaunch, and new restores treat a missing key as empty.
if ! entries=$(jq -ce '
	if type != "object"
	   or ((.sessions // []) | type) != "array"
	   or ((.relaunch // []) | type) != "array"
	then error("invalid assistant sidecar schema")
	else
	  [ (.sessions // [])[] | if type == "object" then . + {kind: "session"} else . end ]
	  + [ (.relaunch // [])[] | if type == "object" then . + {kind: "relaunch"} else . end ]
	end' "$INPUT_FILE" 2>/dev/null); then
	log "invalid assistant sidecar at $INPUT_FILE, skipping restore"
	exit 0
fi
count=$(printf '%s\n' "$entries" | jq 'length')

if [ "$count" -eq 0 ]; then
	log "no assistant panes to restore"
	exit 0
fi

# Wait for panes to be fully initialized after resurrect restore
sleep 2

log "restoring $count assistant pane(s)..."

# Use a temp file to avoid subshell variable scoping issues with pipes
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT INT TERM
printf '%s\n' "$entries" | jq -c '.[]' >"$tmpfile"

restored=0
entry_number=0
claimed_panes="|"
while read -r entry; do
	entry_number=$((entry_number + 1))
	# Treat the sidecar as untrusted input. Besides preventing surprising jq
	# coercions, validating each entry here means one corrupt entry cannot abort
	# restoration of all the valid panes after it.
	if ! printf '%s\n' "$entry" | jq -e '
		def optional_string($k): (has($k) | not) or .[$k] == null or (.[$k] | type) == "string";
		type == "object"
		and (.pane | type) == "string"
		and (.tool | type) == "string"
		and (.kind == "session" or .kind == "relaunch")
		and optional_string("cwd")
		and optional_string("cli_args")
		and optional_string("model")
		and optional_string("copilot_home")
		and optional_string("session_name")
		and optional_string("window_index")
		and optional_string("pane_index")
		and ((has("env") | not) or .env == null or (.env | type) == "object")
		and (if .kind == "session" then (.session_id | type) == "string"
		     else (.cmd | type) == "string" end)' >/dev/null 2>&1; then
		log "malformed sidecar entry $entry_number, skipping"
		continue
	fi

	pane=$(printf '%s\n' "$entry" | jq -r '.pane')
	tool=$(printf '%s\n' "$entry" | jq -r '.tool')
	kind=$(printf '%s\n' "$entry" | jq -r '.kind')
	session_id=$(printf '%s\n' "$entry" | jq -r '.session_id // empty')
	relaunch_cmd=$(printf '%s\n' "$entry" | jq -r '.cmd // empty')
	cwd=$(printf '%s\n' "$entry" | jq -r '.cwd // empty')
	cli_args=$(printf '%s\n' "$entry" | jq -r '.cli_args // empty')
	# The save path stops writing credential flags into the sidecar, but files
	# written before that are still on disk and are read verbatim here. Without
	# this the old value would be replayed into the pane and copied into the
	# restore log, so the save-side fix alone would not close the leak.
	cli_args=$(strip_credential_flags "$cli_args" "saved $tool cli_args")
	model=$(printf '%s\n' "$entry" | jq -r '.model // empty')
	env_json=$(printf '%s\n' "$entry" | jq -c '.env // {}')
	copilot_home=$(printf '%s\n' "$entry" | jq -r '.copilot_home // empty')

	if [ "$kind" = "session" ]; then
		if [ -z "$session_id" ] || [ "${#session_id}" -gt 256 ] ||
			! [[ "$session_id" =~ ^[A-Za-z0-9_][A-Za-z0-9._:/+=-]*$ ]]; then
			log "invalid or empty session id for $tool in $pane, skipping"
			continue
		fi
	fi

	# Resolve the saved pane to a live tmux pane id (%N), which every tmux
	# command below then targets. The saved "session:window.pane" string is a
	# display label, NOT a usable tmux target: session names may contain ':'
	# and '.' (tmux 3.7+ keeps them; 3.4-3.6 rewrote them to '_'), and both are
	# reserved by the target grammar. See resolve_tmux_pane_id() in
	# lib-detect.sh for why neither `-t name` nor `-t =name` can be trusted.
	#
	# Prefer the saved components; fall back to splitting the label for
	# sidecars written before those fields existed (the file is a cache
	# regenerated on every save, so the only path that hits this is
	# save -> upgrade -> restore).
	tmux_session=$(printf '%s\n' "$entry" | jq -r '.session_name // empty')
	window_index=$(printf '%s\n' "$entry" | jq -r '.window_index // empty')
	pane_index=$(printf '%s\n' "$entry" | jq -r '.pane_index // empty')
	if [ -z "$tmux_session" ] || [ -z "$window_index" ] || [ -z "$pane_index" ]; then
		if ! split_pane_target "$pane"; then
			log "malformed pane target '$pane', skipping"
			continue
		fi
		tmux_session="$PANE_TARGET_SESSION"
		window_index="$PANE_TARGET_WINDOW"
		pane_index="$PANE_TARGET_INDEX"
	fi

	pane_id=$(resolve_tmux_pane_id "$tmux_session" "$window_index" "$pane_index" || true)
	if [ -z "$pane_id" ]; then
		log "pane $pane does not exist (session '$tmux_session', window $window_index, pane $pane_index), skipping"
		continue
	fi
	case "$claimed_panes" in
	*"|${pane_id}|"*)
		log "duplicate sidecar entry for pane $pane, skipping"
		continue
		;;
	esac

	# Wait for at least one client to attach to this pane's session before
	# replaying. TUI tools that query the terminal at startup (OSC 11
	# background-color for theme detection, cursor-shape, hyperlinks, etc.)
	# get a null response if no terminal is attached when the query fires
	# — tmux silently drops the query because there's no client to forward
	# it to. crossterm-based tools cache that null response in a OnceLock
	# and never retry, so a single bad startup permanently locks the tool
	# to its fallback state for the lifetime of the process. Symptom seen
	# in the wild: codex's diff palette permanently dark on a light
	# terminal after every reboot, requiring a manual `codex resume` to
	# clear.
	#
	# Poll every 100ms, cap at 5s so we don't hang the rest of the restore
	# if the user never attaches a client. In normal boot flows where a
	# kitty/wezterm/etc auto-attaches via `tmux new-session -A`, the wait
	# resolves in < 200ms.
	#
	# `list-clients` takes a session target, and the session name cannot be one
	# (see above) — but a pane id resolves to its own session, so target that.
	client_wait=0
	while [ "$(tmux list-clients -t "$pane_id" 2>/dev/null | wc -l)" -eq 0 ] && [ $client_wait -lt 50 ]; do
		sleep 0.1
		client_wait=$((client_wait + 1))
	done
	if [ $client_wait -ge 50 ]; then
		log "no client attached to session '$tmux_session' after 5s; replaying anyway (TUI startup queries may miss responses)"
	fi

	# Guard 1: skip if the pane is not running a shell.
	# After tmux-resurrect restore, panes should be running a shell (bash, zsh,
	# etc.). If something else is running (e.g., the user manually started vim,
	# or @resurrect-processes restored a non-assistant program), injecting
	# send-keys would feed commands into the wrong program.
	pane_cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)
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
	pane_shell_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null || true)
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
	# redacted_env_prefix and redacted_nu_env mirror env_prefix and nu_env for log
	# output, with captured values replaced by *** so credentials never reach the
	# restore log. They are kept in each shell's own dialect rather than sharing
	# one string: the log is read as a record of what was sent, so rendering a
	# POSIX VAR=*** inside a Nushell `with-env { }` block would misreport it.
	# Only user-captured values are masked. Plugin-derived values such as
	# COPILOT_HOME are paths, not secrets, and stay readable — they are the whole
	# reason to consult this log when a restore lands on the wrong state root.
	env_prefix=""
	nu_env=""
	redacted_env_prefix=""
	redacted_nu_env=""
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
		reglob=""
		case "$-" in *f*) ;; *) reglob=1 ;; esac
		set -f
		for var in $capture_env; do
			# Validate var name to prevent shell injection via crafted tmux option
			if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				log "skipping invalid env var name: $var"
				continue
			fi
			# A saved Copilot state root is authoritative and is appended below.
			# Avoid duplicate Nushell record keys when users also capture it.
			if [ "$tool" = "copilot" ] && [ "$var" = "COPILOT_HOME" ] && [ -n "$copilot_home" ]; then
				continue
			fi
			val=$(printf '%s\n' "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			if [ -n "$val" ]; then
				env_prefix="${env_prefix}${var}=$(shell_quote "$pane_cmd" "$val") "
				nu_env="${nu_env}${var}: $(shell_quote "$pane_cmd" "$val"), "
				redacted_env_prefix="${redacted_env_prefix}${var}=*** "
				redacted_nu_env="${redacted_nu_env}${var}: ***, "
			fi
		done
		[ -n "$reglob" ] && set +f
	fi

	resume_cmd=""
	if [ "$kind" = "relaunch" ]; then
		# Shape and hazard hints are intentionally absent here. The only gate is
		# exact membership in the current user-owned voucher, and the returned
		# command is rebuilt from that matching voucher line rather than from
		# sidecar bytes.
		relaunch_enabled=$(tmux show-option -gqv @assistant-resurrect-relaunch 2>/dev/null || true)
		relaunch_enabled="${relaunch_enabled:-on}"
		case "$relaunch_enabled" in
		on | yes | true | 1) ;;
		*)
			log "relaunch disabled for $tool in $pane, skipping"
			continue
			;;
		esac
		if [ -z "$relaunch_cmd" ]; then
			log "empty relaunch cmd for $tool in $pane, skipping"
			continue
		fi
		resume_cmd=$(relaunch_command_from_voucher "$tool" "$relaunch_cmd" "$pane_cmd") || {
			log "relaunch cmd not vouched for $tool in $pane: $relaunch_cmd"
			continue
		}
	else
		# Build the resume command for each tool. Quote for the actual pane shell;
		# csh/tcsh expand `!` even inside POSIX single quotes.
		safe_sid=$(shell_quote "$pane_cmd" "$session_id")

		# Quote cli_args tokens and disable glob expansion while splitting, so
		# args like "claude-opus-4-6[1m]" are treated literally.
		safe_cli_args=""
		cli_has_model=0
		if [ -n "$cli_args" ]; then
			reglob=""
			case "$-" in *f*) ;; *) reglob=1 ;; esac
			set -f
			for _arg in $cli_args; do
				safe_cli_args="${safe_cli_args} $(shell_quote "$pane_cmd" "$_arg")"
				case "$_arg" in --model | --model=*) cli_has_model=1 ;; esac
			done
			[ -n "$reglob" ] && set +f
		fi

		# Add --model from the sidecar model field if not already in cli_args.
		# Only for Claude — OpenCode and Codex don't support --model.
		safe_model_arg=""
		if [ -n "$model" ] && [ "$tool" = "claude" ]; then
			if [ "${cli_has_model:-0}" -eq 0 ]; then
				safe_model_arg=" --model $(shell_quote "$pane_cmd" "$model")"
			fi
		fi

		case "$tool" in
	claude)
		if [ -n "$safe_cli_args" ] || [ -n "$safe_model_arg" ]; then
			resume_cmd="command claude${safe_cli_args}${safe_model_arg} --resume ${safe_sid}"
		else
			resume_cmd="command claude --resume ${safe_sid}"
		fi
		;;
	copilot)
		copilot_cmd="command copilot"
		if [ -n "$copilot_home" ]; then
			env_prefix="${env_prefix}COPILOT_HOME=$(shell_quote "$pane_cmd" "$copilot_home") "
			nu_env="${nu_env}COPILOT_HOME: $(shell_quote "$pane_cmd" "$copilot_home"), "
			# Not masked: this is a state-root path the plugin derived itself,
			# not user-supplied credential material.
			redacted_env_prefix="${redacted_env_prefix}COPILOT_HOME=$(shell_quote "$pane_cmd" "$copilot_home") "
			redacted_nu_env="${redacted_nu_env}COPILOT_HOME: $(shell_quote "$pane_cmd" "$copilot_home"), "
		fi
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${copilot_cmd}${safe_cli_args} --resume=${safe_sid}"
		else
			resume_cmd="${copilot_cmd} --resume=${safe_sid}"
		fi
		;;
	opencode)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command opencode${safe_cli_args} -s ${safe_sid}"
		else
			resume_cmd="command opencode -s ${safe_sid}"
		fi
		;;
	codex)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command codex${safe_cli_args} resume ${safe_sid}"
		else
			resume_cmd="command codex resume ${safe_sid}"
		fi
		;;
	pi)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command pi${safe_cli_args} --session ${safe_sid}"
		else
			resume_cmd="command pi --session ${safe_sid}"
		fi
		;;
	omp)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command omp${safe_cli_args} --resume ${safe_sid}"
		else
			resume_cmd="command omp --resume ${safe_sid}"
		fi
		;;
	grok)
		# Deliberately ignore cli_args for grok. Resuming reloads the
		# session's own model/agent/context from disk, and grok's prompt is a
		# positional argument — replaying captured args risks re-submitting a
		# stale prompt into the resumed session. A clean `grok --resume <id>`
		# is the correct restore. The generic cwd `cd` below still runs first,
		# which also lets grok locate the (cwd-scoped) session directory.
		resume_cmd="command grok --resume ${safe_sid}"
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac
	fi

	# csh/tcsh have no `command` builtin, so the POSIX form below cannot be used
	# there even when no env vars were captured. macOS happens to ship
	# /usr/bin/command as an external script, which hides the breakage; on Linux
	# the line dies with "command: Command not found." and the pane is left at a
	# shell. `env` is the wrapper this script already uses whenever captured env
	# vars exist, so force those shells through it unconditionally.
	#
	# `env` alone is not the alias-bypass that `command` is: csh applies alias
	# substitution to the first word, so a user's `alias env ...` intercepts the
	# restore. A leading backslash suppresses that lookup and is the closest csh
	# equivalent of `command`. It does not disturb the assignments that follow.
	#
	# These are variables rather than a separate case arm so csh/tcsh keep
	# sharing every other transformation applied below.
	force_env=0
	env_launcher="env"
	case "$pane_cmd" in
	csh | tcsh)
		force_env=1
		env_launcher='\env'
		;;
	esac

	# Bypass aliases/functions without relying on POSIX assignment-prefix syntax,
	# which csh/tcsh reject. Nushell uses `^` for an external command and
	# `with-env` for scoped environment changes.
	# Build log_cmd in parallel with the env-values redacted to VAR=***, so
	# captured credentials never leak into the restore log.
	log_cmd="$resume_cmd"
	case "$pane_cmd" in
	nu)
		resume_cmd="^${resume_cmd#command }"
		log_cmd="^${log_cmd#command }"
		if [ -n "$nu_env" ]; then
			nu_env="${nu_env%, }"
			resume_cmd="with-env { ${nu_env} } { ${resume_cmd} }"
		fi
		if [ -n "$redacted_nu_env" ]; then
			log_cmd="with-env { ${redacted_nu_env%, } } { ${log_cmd} }"
		elif [ -n "$nu_env" ]; then
			log_cmd="$resume_cmd"
		fi
		;;
	*)
		if [ -n "$env_prefix" ] || [ "$force_env" -eq 1 ]; then
			resume_cmd="${env_launcher} ${env_prefix}${resume_cmd#command }"
		fi
		if [ -n "$redacted_env_prefix" ]; then
			# Mirror whatever launcher the resume line above used, so the log
			# keeps describing the command that was actually sent. Defaulted
			# because env_launcher is set by the csh handling, which this
			# branch does not itself introduce.
			log_cmd="${env_launcher:-env} ${redacted_env_prefix}${log_cmd#command }"
		elif [ -n "$env_prefix" ] || [ "${force_env:-0}" -eq 1 ]; then
			# force_env covers shells that are routed through `env` even with no
			# captured vars; without it the log would keep the untransformed
			# command and advertise a form that was never sent to the pane.
			log_cmd="$resume_cmd"
		fi
		;;
	esac

	# Resolve the working directory before touching the pane. A stale saved cwd
	# must not leave the user with a cleared shell or resume into the wrong
	# project. `&&` also covers the small disappearance/permission race between
	# this check and execution in the pane.
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		if [ ! -d "$cwd" ]; then
			log "saved cwd for $tool in $pane no longer exists, skipping"
			continue
		fi
		safe_cwd=$(shell_quote "$pane_cmd" "$cwd")
		case "$pane_cmd" in
		nu)
			# Nushell sequences statements with `;`; POSIX-style `&&` is not
			# accepted by current Nushell releases. A failed `cd` is a shell
			# error, so the following external command is not evaluated.
			full_cmd="cd ${safe_cwd}; ${resume_cmd}"
			;;
		*) full_cmd="cd ${safe_cwd} && ${resume_cmd}" ;;
		esac
	else
		full_cmd="$resume_cmd"
	fi

	if [ "$kind" = "relaunch" ]; then
		log "relaunching $tool in $pane (cmd: $log_cmd)"
	else
		log "restoring $tool in $pane (session: $session_id, cmd: $log_cmd)"
	fi

	# Clear the pane before launching: tmux-resurrect may have restored old
	# pane contents (captured terminal text from the previous session). Without
	# clearing, TUI tools like Claude show stale output above the new instance.
	# Uses tmux clear-history to wipe scrollback, then sends 'clear' to reset
	# the visible area.
	if ! tmux send-keys -t "$pane_id" "clear" Enter 2>/dev/null ||
		! tmux clear-history -t "$pane_id" 2>/dev/null; then
		log "pane $pane disappeared while clearing, skipping"
		continue
	fi
	sleep 0.3

	if ! tmux send-keys -t "$pane_id" "$full_cmd" Enter 2>/dev/null; then
		log "pane $pane disappeared before replay, skipping"
		continue
	fi
	claimed_panes="${claimed_panes}${pane_id}|"

	restored=$((restored + 1))

	# Stagger launches to avoid overwhelming the system
	sleep 1
done <"$tmpfile"

rm -f "$tmpfile"

log "restored $restored of $count assistant pane(s)"
