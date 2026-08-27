#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   relaunch_canon <tool> <argv> — canonical session-less command, or failure
#   relaunch_shape_ok <canon>    — advisory candidate-shape filter
#   relaunch_voucher_match <tool> <canon> — exact vouched line, or failure
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found
#   split_pane_target <target>   — splits "session:window.pane" into its parts
#   match_pane_id <s> <w> <p>    — filters a pane table on stdin to one pane id
#   resolve_tmux_pane_id <s> <w> <p> — prints the live %N for a saved pane
#   resurrect_data_dir           — prints tmux-resurrect's save directory

# --- detect_tool ---
# Match the executable token (or a script passed directly to a known runtime),
# standalone or with arguments. Handles: /path/to/claude, claude,
# node /path/to/copilot, bash /path/to/opencode, etc.
# Excludes: opencode run ... (LSP subprocesses), omp __omp_worker_* subprocesses
detect_tool() {
	local args="$1"
	local reglob="" first tool=""
	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# ps has already flattened argv, but executable and script paths normally
	# have no whitespace. Looking only at these leading tokens prevents an
	# unrelated process argument such as `vim /tmp/claude` from becoming an
	# assistant match.
	# shellcheck disable=SC2086 # deliberate tokenization of flattened ps argv
	set -- $args
	[ -n "$reglob" ] && set +f
	[ "$#" -gt 0 ] || return 0

	first="${1##*/}"
	case "$first" in
	claude | copilot | opencode | codex | pi | omp | grok)
		tool="$first"
		shift
		;;
	node | nodejs | bun | deno | bash | sh | dash | ksh | zsh)
		[ "$#" -gt 1 ] || return 0
		case "${2##*/}" in
		claude | copilot | opencode | codex | pi | omp | grok) tool="${2##*/}" ;;
		*) return 0 ;;
		esac
		shift 2
		;;
	*) return 0 ;;
	esac

	# These are internal child modes, not the interactive assistant. Check the
	# first argument after the actual tool token so prompt text containing the
	# same words does not hide a genuine assistant process.
	if [ "$tool" = "opencode" ] && [ "${1:-}" = "run" ]; then
		return 0
	fi
	if [ "$tool" = "omp" ]; then
		case "${1:-}" in __omp_worker_*) return 0 ;; esac
	fi
	printf '%s\n' "$tool"
}

# --- session-less relaunch vouchers ---

# Canonicalize the flattened argv reported by ps. This is deliberately a
# small, idempotent transform: it validates argv[0], removes the duplicate
# Node script path form (`claude /path/to/claude ...`), and joins tokens with
# one space. It does not interpret shell syntax or decide that a command is
# safe to run; exact membership in the user-owned voucher file is the only
# authorization gate.
relaunch_canon() {
	local tool="$1" raw_args="$2"
	local first token result reglob=""
	[ "$(detect_tool "$tool")" = "$tool" ] || return 1

	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2086 # ps argv is intentionally split into tokens.
	set -- $raw_args
	[ -n "$reglob" ] && set +f
	[ "$#" -gt 0 ] || return 1

	first="$1"
	[ "${first##*/}" = "$tool" ] || return 1
	shift

	# Node-based launchers can expose the script path as a second copy of the
	# tool name. Mirror extract_cli_args() and remove that one token.
	if [ "$#" -gt 0 ]; then
		case "$1" in
		-*) ;;
		*/"$tool") shift ;;
		esac
	fi

	result="$tool"
	for token in "$@"; do
		result="$result $token"
	done
	printf '%s\n' "$result"
}

# Structural proposer for the advisory candidates ledger. Passing this filter
# never authorizes a relaunch. Keep it conservative because ps has already lost
# quoting boundaries; commands it cannot round-trip cleanly should not be
# suggested to the user.
relaunch_shape_ok() {
	local canon="$1" token flag_name
	local token_count=0 positional_count=0 byte_count reglob=""
	local flag_re='^--?[A-Za-z0-9][A-Za-z0-9._-]*(=[^[:space:]]{0,64})?$'
	local positional_re='^[a-z][a-z0-9-]{0,31}$'

	byte_count=$(printf '%s' "$canon" | LC_ALL=C wc -c | tr -d ' ')
	[ "$byte_count" -le 128 ] || return 1
	printf '%s' "$canon" | LC_ALL=C grep -Eq '^[ -~]+$' || return 1

	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2086 # canonical argv is intentionally tokenized.
	set -- $canon
	[ -n "$reglob" ] && set +f
	[ "$#" -gt 1 ] || return 1
	[ "$#" -le 10 ] || return 1
	shift # validated tool token; relaunch_canon() owns that check

	for token in "$@"; do
		token_count=$((token_count + 1))
		[ "$token" != "--" ] || return 1
		case "$token" in
		-*)
			[[ "$token" =~ $flag_re ]] || return 1
			flag_name="${token%%=*}"
			# Candidate commands are written to an advisory ledger. Never
			# persist values attached to credential-shaped options there.
			case "$flag_name" in
			--api-key | --api-key-* | --api_key | --api_key_* | --token | --token-* | --token_* | --secret* | --password | --password-* | --password_* | --auth*)
				return 1
				;;
			esac
			# Prompt-bearing modes are one-shot work, not long-lived modes.
			# This list is advisory-only and must never be used as the voucher
			# authorization gate in save or restore.
			case "$flag_name" in
			-p | --print | --prompt | -i | --interactive | -m | --message | -q | --query | --input | --instruction | --instructions | --task)
				return 1
				;;
			esac
			;;
		*)
			[[ "$token" =~ $positional_re ]] || return 1
			positional_count=$((positional_count + 1))
			[ "$positional_count" -le 2 ] || return 1
			;;
		esac
	done

	[ "$token_count" -gt 0 ] && [ "$positional_count" -ge 1 ]
}

# Resolve the user-owned voucher file. An unset tmux option follows the
# tmux-resurrect save directory; tests and unusual installations can keep using
# TMUX_RESURRECT_DIR through resurrect_data_dir().
relaunch_voucher_file() {
	local configured
	configured=$(tmux show-option -gqv @assistant-resurrect-relaunch-allow-file 2>/dev/null || true)
	if [ -n "$configured" ]; then
		printf '%s\n' "$configured"
	else
		printf '%s/assistant-relaunch-allow.txt\n' "$(resurrect_data_dir)"
	fi
}

# Print the exact matching line from the voucher file. The sidecar value must
# already be canonical: normalizing a tampered lookup key here would weaken the
# whole-line byte-equality guarantee. CRLF line endings are accepted, but
# trailing spaces remain significant and therefore do not match.
relaunch_voucher_match() {
	local tool="$1" canon="$2" file normalized line
	normalized=$(relaunch_canon "$tool" "$canon") || return 1
	[ "$normalized" = "$canon" ] || return 1

	file=$(relaunch_voucher_file)
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		# Canonical commands cannot begin with whitespace, so all such lines
		# are safely ignorable alongside blank lines and comments.
		case "$line" in
		'' | \#* | [[:space:]]*) continue ;;
		esac
		if [ "$line" = "$canon" ]; then
			printf '%s\n' "$line"
			return 0
		fi
	done <"$file"
	return 1
}

# Build a shell-safe command only from a line returned by the voucher matcher.
# Metacharacters introduced by expansion are ordinary argv bytes, and every
# token is quoted for the restored pane's shell before send-keys sees it.
relaunch_command_from_voucher() {
	local tool="$1" canon="$2" shell_name="${3:-sh}"
	local line rest="" token reglob=""
	line=$(relaunch_voucher_match "$tool" "$canon") || return 1

	case "$-" in
	*f*) ;;
	*) reglob=1 ;;
	esac
	set -f
	# shellcheck disable=SC2086 # the vouched canonical line is tokenized as argv.
	set -- $line
	[ -n "$reglob" ] && set +f
	[ "$#" -gt 0 ] && [ "$1" = "$tool" ] || return 1
	shift
	for token in "$@"; do
		rest="$rest $(shell_quote "$shell_name" "$token")"
	done
	printf 'command %s%s\n' "$tool" "$rest"
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

	# Walk the entire process tree under the pane shell. Build the whole parent
	# map before traversing it: POSIX does not promise `ps` ordering, and a
	# child-before-parent row must not let restore launch a second assistant.
	local found_pid
	found_pid=$(printf '%s\n' "$snapshot" | awk -v root="$shell_pid" '
		{
			pid = $1
			ppid = $2
			line = $0
			sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
			args[pid] = line
			children[ppid] = (ppid in children) ? children[ppid] SUBSEP pid : "" pid
		}
		END {
			seen[root] = 1
			queue[++tail] = root
			while (head < tail) {
				cur = queue[++head]
				if (!(cur in children)) continue
				n = split(children[cur], kids, SUBSEP)
				for (i = 1; i <= n; i++) {
					child = kids[i] + 0
					if (child <= 0 || child in seen) continue
					seen[child] = 1
					queue[++tail] = child
					print child, args[child]
				}
			}
		}
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

# --- split_pane_target ---
# Split a saved "session:window.pane" target into its parts, setting
# PANE_TARGET_SESSION, PANE_TARGET_WINDOW and PANE_TARGET_INDEX.
# Returns 1 (leaving the variables untouched) if the target is not that shape.
#
# Splitting from the RIGHT is exact: the window and pane parts are always
# indices, so the LAST ':' and the LAST '.' are the real separators. Splitting
# from the left is not exact — tmux allows both characters in a session name, so
# "${target%%:*}" turns "https://host/x:0.0" into "https".
# shellcheck disable=SC2034  # PANE_TARGET_* are out-parameters, read by callers
split_pane_target() {
	local target="$1" win_pane
	case "$target" in
	*:*.*) ;;
	*) return 1 ;;
	esac
	win_pane="${target##*:}"
	PANE_TARGET_SESSION="${target%:*}"
	PANE_TARGET_WINDOW="${win_pane%.*}"
	PANE_TARGET_INDEX="${win_pane##*.}"
}

# --- match_pane_id ---
# Read a "#{pane_id}|#{window_index}|#{pane_index}|#{session_name}" table on
# stdin and print the pane id whose fields equal <session> <window> <index>.
# Prints nothing when there is no match. Split out from resolve_tmux_pane_id()
# so the matching can be tested without a tmux server.
#
# The session name is last because it is the only field that may contain the '|'
# delimiter: awk peels the fixed-shape fields off the front and takes the
# remainder verbatim. A control-character delimiter would avoid the problem but
# is not portable — tmux < 3.7 rewrites those in -F output, differently per
# version (see AGENTS.md "Pipe delimiter in tmux format output").
#
# The values are passed through the environment rather than `awk -v`, which
# expands backslash escapes and would corrupt a name containing a backslash.
match_pane_id() {
	TAR_SESSION="$1" TAR_WINDOW="$2" TAR_INDEX="$3" awk '
		BEGIN { s = ENVIRON["TAR_SESSION"]; w = ENVIRON["TAR_WINDOW"]; p = ENVIRON["TAR_INDEX"] }
		{
			rec = $0
			i = index(rec, "|"); if (i == 0) next
			id  = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			i = index(rec, "|"); if (i == 0) next
			win = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			i = index(rec, "|"); if (i == 0) next
			idx = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			if (found == "" && rec == s && win == w && idx == p) { found = id }
		}
		END { if (found != "") print found }
	'
}

# --- resolve_tmux_pane_id ---
# Print the live pane id (%N) of the pane identified by <session> <window>
# <index>, or nothing if no such pane exists on this server.
#
# Why not just hand tmux the "session:window.pane" string? Because tmux's target
# grammar reserves ':' and '.' but session names may contain them, and tmux also
# prefix-matches session names. A session named "v1.2" makes
# `has-session -t v1.2` fail with "can't find pane: 2"; a session named
# "https://host/x" makes it succeed against a *different* session. `-t '=name'`
# does not help either — the grammar splits before the exact match is applied.
# Comparing the parts literally against list-panes output sidesteps the grammar
# entirely, and the %N it yields is accepted verbatim by every tmux command.
#
# Pane ids are only unique within one tmux server lifetime — the exact boundary
# this plugin operates across — so they are resolved here at restore time and
# never persisted.
resolve_tmux_pane_id() {
	tmux list-panes -a -F '#{pane_id}|#{window_index}|#{pane_index}|#{session_name}' 2>/dev/null |
		match_pane_id "$1" "$2" "$3"
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

# Quote one value for the shell running in a restored pane. csh/tcsh perform
# history expansion inside single quotes and use different embedded-quote
# rules, so escape `!` and use their `'\''` sequence for a literal quote.
# Other supported shells accept posix_quote().
shell_quote() {
	local shell_name="$1" val="$2"
	case "$shell_name" in
	csh | tcsh)
		local quote_escape="'\\''"
		val="${val//!/\\!}"
		val="${val//\'/$quote_escape}"
		printf "'%s'" "$val"
		;;
	*) posix_quote "$val" ;;
	esac
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

# Directory holding the per-process assistant state files (claude-<pid>.json,
# opencode-<pid>.json).
#
# Resolution order:
#   1. $TMUX_ASSISTANT_RESURRECT_DIR — explicit override (tests / unusual setups)
#   2. $HOME/.local/state/tmux-assistant-resurrect
#
# Why this is a plain $HOME literal and not $XDG_STATE_HOME / $XDG_RUNTIME_DIR /
# $TMPDIR — this path is a *rendezvous point between two processes that never
# share an environment*: the SessionStart hook writes as a child of the assistant,
# the save hook reads as a child of the tmux server. Every environment variable in
# the expression is therefore a chance for the two sides to disagree, and when they
# do the failure is silent — the save hook finds no state file and falls back to
# scraping --resume out of argv, recording a missing or (worse) a stale ID from a
# previous session.
#
# The previous ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}} chain broke exactly that way:
# Claude Code's settings.json can set "env": {"TMPDIR": ...} — common, because /tmp
# is mounted noexec in many containers — which the hook inherits and the tmux server
# does not. $XDG_STATE_HOME would reintroduce the same bug with a rarer trigger, so
# it is deliberately not consulted. $HOME is the one variable both sides are already
# guaranteed to agree on: Claude Code resolved ~/.claude/settings.json through it and
# tmux read ~/.tmux.conf through it. Same reasoning as the $HOME-only substitution in
# the stored hook paths (see AGENTS.md, "portable hook paths").
#
# Note this deliberately differs from resurrect_data_dir() above, which *does* honour
# $XDG_DATA_HOME. That one is only ever resolved inside the save/restore scripts, so
# it has no second process to disagree with.
#
# To relocate the directory, set TMUX_ASSISTANT_RESURRECT_DIR where BOTH sides see it
# (`tmux set-environment -g` plus the assistant's own env config). Exporting it from a
# shell profile reaches only the assistant, and reintroduces the divergence.
assistant_state_dir() {
	if [ -n "${TMUX_ASSISTANT_RESURRECT_DIR:-}" ]; then
		echo "$TMUX_ASSISTANT_RESURRECT_DIR"
		return
	fi
	echo "${HOME:?tmux-assistant-resurrect: HOME is unset; set TMUX_ASSISTANT_RESURRECT_DIR instead}/.local/state/tmux-assistant-resurrect"
}

# Create the state directory if it is missing, private to its owner. Shared by both
# writers for the same reason assistant_state_dir() is: they run in different process
# environments and must not drift.
#
# Not `mkdir -p -m 0700`, which is wrong twice over. SC2174: `-m` applies only to the
# deepest directory, so now that the path is three levels under $HOME it never
# protected $HOME/.local or $HOME/.local/state anyway -- and those want the umask
# default, 0755 being the XDG convention. Worse, Git Bash fails the call outright when
# the path does not pre-exist, and under `set -e` that killed the whole save before it
# wrote anything; the Windows canary is what caught it.
#
# Not `mkdir -p` followed by `chmod 700` either, which is what that first fix did:
#   - it leaves the directory at the umask default until the chmod lands, so a
#     concurrent reader gets a window, one that widens to world-writable at umask 000;
#   - `chmod` follows symlinks, so a link left at $STATE_DIR gets its *target*
#     re-moded;
#   - it fires on every save, resetting a mode the user chose deliberately -- a
#     group-readable TMUX_ASSISTANT_RESURRECT_DIR would be clamped back to 0700 every
#     five minutes by continuum.
# Creating the leaf under a scoped umask closes all three: the mode is applied
# atomically by mkdir(2), and an existing directory is left exactly as it is.
ensure_assistant_state_dir() {
	local dir="${1:-}" parent
	[ -n "$dir" ] || return 0
	[ -d "$dir" ] && return 0

	while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
	parent="${dir%/*}"
	if [ -n "$parent" ] && [ "$parent" != "$dir" ]; then
		mkdir -p "$parent" 2>/dev/null || true
	fi
	# The fallback is `-p` under the same umask, not a bare one: the leaf-only mkdir
	# above fails if the parent creation was itself refused, and dropping to an
	# ambient-mode create there would hand back exactly the 0755 state dir this
	# function exists to avoid. It also absorbs the benign race where the other
	# writer won between the -d test and here, since `mkdir -p` on an existing
	# directory succeeds. Deliberately unguarded: a genuine failure (no space, a
	# read-only $HOME) should still abort under `set -e`, as it did before.
	(umask 077 && mkdir "$dir") 2>/dev/null || (umask 077 && mkdir -p "$dir")
}

# The pre-$HOME default locations, newline-separated, most-likely first. Used only by
# the save hook, to migrate state files written by hooks that ran before the upgrade —
# without it, every already-running assistant loses its session ID until it is
# restarted, and continuum overwrites the good sidecar within five minutes.
#
# Why a *set* and not one resolved path: the old expression was
# ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect, and issue #65 is
# precisely that it resolved differently in the writer's environment than in the
# reader's. Evaluating it once here resolves it in the reader's — so it would migrate
# only the users whose two sides already agreed, i.e. the ones who were never broken,
# and find nothing for the ones who were.
#
# So enumerate every location a pre-upgrade hook could plausibly have written to,
# whether or not this process's environment names it:
#   $XDG_RUNTIME_DIR   the reader's, when it has one
#   /run/user/<uid>    the systemd default — covers the reader having no
#                      XDG_RUNTIME_DIR while the hook, run from a login session, did
#   $TMPDIR            the reader's, when it has one
#   /var/folders/<hash>/T  macOS's per-uid temp dir, but only when this side has no
#                      $TMPDIR of its own -- covers a tmux server started by launchd
#                      or over ssh, which inherits none, while the hook that wrote
#                      the file did. It is keyed on uid, not on the login session, so
#                      it resolves to the same path the writer used.
#   /tmp               the final fallback of the old chain
#
# Still not discoverable from this side: a settings.json naming a private TMPDIR for
# the assistant alone. That residue is what missing_session_hint()'s diagnostic exists
# to explain.
#
# Deliberately fork-free (no sed/id) on the hot path: this runs on every save cycle.
# The one `getconf` is gated twice -- a normal macOS shell always exports $TMPDIR, and
# /var/folders does not exist off Darwin -- so in practice it never runs.
legacy_assistant_state_dirs() {
	if [ -n "${TMUX_ASSISTANT_RESURRECT_DIR:-}" ]; then
		return
	fi

	local nl='
'
	local current uid seen="" base dir darwin_tmp=""
	current=$(assistant_state_dir)
	uid="${EUID:-${UID:-}}"

	if [ -z "${TMPDIR:-}" ] && [ -d /var/folders ]; then
		# `|| darwin_tmp=""` is load-bearing: the save hook runs under `set -e`, and a
		# getconf that does not know the key exits non-zero.
		darwin_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || darwin_tmp=""
	fi

	for base in \
		"${XDG_RUNTIME_DIR:-}" \
		"${uid:+/run/user/$uid}" \
		"${TMPDIR:-}" \
		"$darwin_tmp" \
		/tmp; do
		[ -n "$base" ] || continue
		# Strip the trailing slash $TMPDIR usually carries, so the dedupe below and
		# the log line both show a canonical path.
		while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
		dir="$base/tmux-assistant-resurrect"
		[ "$dir" = "$current" ] && continue
		case "$nl$seen" in
		*"$nl$dir$nl"*) continue ;;
		esac
		seen="$seen$dir$nl"
	done

	printf '%s' "$seen"
}
