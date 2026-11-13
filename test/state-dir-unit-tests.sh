#!/usr/bin/env bash
# Hermetic unit tests for assistant state-directory resolution (issue #65).
#
# The state dir is a rendezvous point between two processes that never share an
# environment: the SessionStart hook writes as a child of the assistant, the save
# hook reads as a child of the tmux server. If the two resolve it differently the
# failure is silent — the save hook simply finds nothing and records no session
# ID. These tests pin that they agree.
#
# Why a separate file rather than more cases in test/run-tests.sh: that suite
# exports TMUX_ASSISTANT_RESURRECT_DIR globally at the top, which short-circuits
# the resolver before any of the interesting logic runs. That single export is
# why #65 shipped green. NOTHING HERE MAY EXPORT IT — each case sets it, or
# deliberately does not, for itself.
#
# Also unlike run-tests.sh (Docker/Linux only), this runs on macOS and Git Bash,
# which is where the real divergence lives: $TMPDIR is /var/folders/<hash>/T on
# macOS and per-login-session, so the tmux server and a freshly-launched
# assistant genuinely disagree.
#
# Run locally with:  bash test/state-dir-unit-tests.sh   (or: just test-state-dir)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SANDBOX="$(mktemp -d)" || exit 1
[ -d "$SANDBOX" ] || exit 1
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

# shellcheck source=lib-assert.sh
source "$REPO_DIR/test/lib-assert.sh"

# Which interpreter the code *under test* runs under. The harness itself runs
# under whatever invoked it, but every tested function is exercised in a child
# shell — and hardcoding `bash` there meant the CI matrix's bash 3.2 job proved
# only that this file parses under 3.2, never that lib-detect.sh and the save
# hook behave under it. $BASH is the running interpreter's own path, so
# `bash3.2 test/state-dir-unit-tests.sh` now exercises 3.2 end to end.
UNDER_TEST="${BASH:-bash}"

# Write a fixture file, creating its directory, and fail loudly if that did not
# work. This suite runs without `set -e` (a failed case must not abort the rest),
# which means a failed mkdir or write would otherwise sail past silently — and
# every "... was reaped" / "... no longer in the old dir" assertion below is an
# *absence* check that a never-created file satisfies. Vacuous green is the one
# failure mode a regression suite cannot afford; #65 shipped through exactly that.
fixture() {
	local path="$1" content="$2"
	mkdir -p "$(dirname "$path")" 2>/dev/null
	printf '%s\n' "$content" >"$path" 2>/dev/null
	if [ ! -f "$path" ]; then
		FAIL=$((FAIL + 1))
		printf '  [FAIL] fixture could not be created: %s\n' "$path"
	fi
}

# Run a snippet in a fresh bash with a controlled environment. The override is
# always unset first so a case has to opt in to it; callers pass the rest as
# NAME=VALUE arguments before the snippet.
#
# Sourcing save-assistant-sessions.sh defines its functions without running
# main() (see AGENTS.md), but its top-level lines do mkdir the state and
# resurrect dirs — hence the sandboxed HOME every caller passes.
#
# Set IN_ENV_ERR to a path first to keep the snippet's stderr instead of discarding
# it, and clear it again afterwards (the assignment inside a command substitution
# cannot reset it for you). Cases asserting on an exit code need this: sourcing the
# save script under `set -euo pipefail` dies before `echo rc=$?` if any top-level
# line fails, and the assertion then sees a bare empty string with no clue why.
IN_ENV_ERR=""
in_env() {
	local snippet="${*: -1}"
	local -a assignments=("${@:1:$#-1}")
	env -u TMUX_ASSISTANT_RESURRECT_DIR -u XDG_RUNTIME_DIR -u XDG_STATE_HOME \
		"${assignments[@]}" "$UNDER_TEST" -c "$snippet" 2>"${IN_ENV_ERR:-/dev/null}"
}

# Fold a captured stderr into an empty result, so "it died at source time" reports
# the reason rather than an unexplained blank.
or_stderr() {
	local out="$1" errfile="$2"
	if [ -n "$out" ]; then
		printf '%s' "$out"
	else
		printf 'no output; stderr: %s' "$(tr '\n' ' ' <"$errfile" 2>/dev/null)"
	fi
}

# Octal mode of a path, or "?" where that cannot be determined — BSD and GNU stat
# disagree on the flag, and Git Bash emulates modes loosely enough that the answer
# is not meaningful. Callers must skip on "?" rather than assert against it: a mode
# assertion that silently compares "?" to "?" is exactly the kind of vacuous pass
# this suite exists to prevent.
perms_of() {
	local p="$1" m
	[ -e "$p" ] || {
		printf '?'
		return
	}
	m=$(stat -f '%Lp' "$p" 2>/dev/null) || m=""
	[ -n "$m" ] || m=$(stat -c '%a' "$p" 2>/dev/null) || m=""
	case "$m" in
	'' | *[!0-7]*) printf '?' ;;
	*) printf '%s' "${m#"${m%???}"}" ;;
	esac
}

# Does this filesystem honour POSIX modes at all? Git Bash emulates permissions over
# Windows ACLs: `chmod` is largely a no-op and `stat` still answers with a
# plausible-looking octal that has nothing to do with what was asked for — so
# perms_of() returns "755", not "?", and a mode assertion fails for a reason that is
# not a bug. Probe once with a control directory whose mode we set two different ways
# and check both come back, rather than trusting the answer per-case.
modes_are_real() {
	local d="$SANDBOX/.modeprobe"
	rm -rf "$d" 2>/dev/null
	(umask 077 && mkdir -p "$d") 2>/dev/null || return 1
	[ "$(perms_of "$d")" = "700" ] || return 1
	chmod 755 "$d" 2>/dev/null || return 1
	[ "$(perms_of "$d")" = "755" ] || return 1
	return 0
}
if modes_are_real; then MODES_REAL=1; else MODES_REAL=0; fi

# --- harness self-check ---
#
# Everything below asserts on the behaviour of a *child* shell, so if that child is
# not the interpreter the caller selected, the whole bash-3.2 half of the CI matrix
# proves nothing but that this file parses. It said "62 passed" under bash3.2 while
# running every tested function under bash 5. A suite whose job is to catch silent
# failures has no business failing silently itself.

echo "== harness self-check =="

# shellcheck disable=SC2016  # the child must expand this, not the harness
assert_eq "the code under test runs on the interpreter running this suite" \
	"${BASH_VERSINFO[0]}" \
	"$("$UNDER_TEST" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)"

# --- assistant_state_dir() ---

echo "== assistant_state_dir =="

LIB="$REPO_DIR/scripts/lib-detect.sh"

out=$(in_env "HOME=$SANDBOX/h1" "source '$LIB'; TMUX_ASSISTANT_RESURRECT_DIR=/explicit/override assistant_state_dir")
assert_eq "explicit \$TMUX_ASSISTANT_RESURRECT_DIR wins" "/explicit/override" "$out"

out=$(in_env "HOME=$SANDBOX/h1" "source '$LIB'; assistant_state_dir")
assert_eq "default is \$HOME/.local/state/tmux-assistant-resurrect" \
	"$SANDBOX/h1/.local/state/tmux-assistant-resurrect" "$out"

# THE regression test for #65. Two environments that differ in exactly the ways a
# hook's and the tmux server's do — Claude Code's settings.json can set TMPDIR,
# and XDG_RUNTIME_DIR exists for a login session but not for a daemonised server
# — must still land on the same directory. Under the old
# ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}} chain these two produced
# /writer-run/tmux-assistant-resurrect and /tmp/tmux-assistant-resurrect.
#
# Both sides are asserted against the expected literal rather than against each
# other: writer = reader alone is satisfied when both are empty, which is what
# happens on pre-fix code where assistant_state_dir does not exist and stderr is
# discarded. The regression test for a silent failure must not be able to pass
# silently itself.
RDV_EXPECTED="$SANDBOX/h1/.local/state/tmux-assistant-resurrect"
writer=$(env -u TMUX_ASSISTANT_RESURRECT_DIR \
	"HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/writer-tmp" "XDG_RUNTIME_DIR=$SANDBOX/writer-run" \
	"$UNDER_TEST" -c "source '$LIB'; assistant_state_dir" 2>/dev/null)
reader=$(env -u TMUX_ASSISTANT_RESURRECT_DIR -u TMPDIR -u XDG_RUNTIME_DIR \
	"HOME=$SANDBOX/h1" \
	"$UNDER_TEST" -c "source '$LIB'; assistant_state_dir" 2>/dev/null)
assert_eq "writer anchors on \$HOME despite TMPDIR + XDG_RUNTIME_DIR" "$RDV_EXPECTED" "$writer"
assert_eq "reader anchors on \$HOME with neither set" "$RDV_EXPECTED" "$reader"

# XDG_STATE_HOME is deliberately NOT consulted: it is one more variable the two
# sides could disagree about, for no benefit the override does not already give.
out=$(env -u TMUX_ASSISTANT_RESURRECT_DIR "HOME=$SANDBOX/h1" "XDG_STATE_HOME=$SANDBOX/xdg-state" \
	"$UNDER_TEST" -c "source '$LIB'; assistant_state_dir" 2>/dev/null)
assert_eq "XDG_STATE_HOME is ignored" \
	"$SANDBOX/h1/.local/state/tmux-assistant-resurrect" "$out"

# No $HOME and no override is unrecoverable — fail loudly rather than silently
# writing to /.local/state, which the reader would never find either.
out=$(env -u TMUX_ASSISTANT_RESURRECT_DIR -u HOME "$UNDER_TEST" -c "source '$LIB'; assistant_state_dir" 2>&1)
assert_contains "unset \$HOME with no override errors instead of guessing" \
	"$out" "TMUX_ASSISTANT_RESURRECT_DIR"

# --- ensure_assistant_state_dir() ---

echo "== ensure_assistant_state_dir =="

# The first fix for the Git Bash `mkdir -p -m 0700` failure was `mkdir -p` plus an
# unconditional `chmod 700`, which regressed three ways at once. These pin all three
# plus the original bug.

# 1. It must create the whole three-level path. `mkdir -p -m 0700` did not, on Git
#    Bash, and under `set -e` that took the entire save down with it — which is the
#    failure the Windows canary surfaced. Assert on the directory, not on an exit
#    code, since the broken version could exit 0 having made nothing.
esd_new="$SANDBOX/esd-home/.local/state/tmux-assistant-resurrect"
# `umask 022` is pinned, not inherited: the parent assertion below says the leaf's
# 0700 did not leak upwards, and under a developer's own `umask 077` the parents
# would be 0700 for a legitimate reason — the assertion would fail on a machine
# where nothing is wrong. Fixing the umask is what makes the two modes distinguish.
in_env "HOME=$SANDBOX/esd-home" "umask 022; source '$LIB'; ensure_assistant_state_dir '$esd_new'"
assert_eq "creates the full \$HOME/.local/state path" "yes" \
	"$([ -d "$esd_new" ] && echo yes || echo no)"

# 2. The leaf must be private, and applied by mkdir(2) itself rather than by a
#    follow-up chmod — there is no window to observe here, but the mode still has to
#    land. Parents keep the umask default: 0755 is the XDG convention for ~/.local
#    and ~/.local/state, and clamping them to 0700 would be a side effect on paths
#    that are not ours.
if [ "$MODES_REAL" = 0 ]; then
	skip "new state dir is private to the owner" "this filesystem does not honour POSIX modes"
else
	esd_mode=$(perms_of "$esd_new")
	esd_parent_mode=$(perms_of "$SANDBOX/esd-home/.local/state")
	assert_eq "new state dir is private to the owner" "700" "$esd_mode"
	# Whatever the runner's umask is, the parent must not have been forced to 0700
	# by a umask that leaked out of the leaf's creation.
	assert_eq "parents are not clamped to 0700" "no" \
		"$([ "$esd_parent_mode" = "700" ] && echo yes || echo no)"
fi

# 3. An existing directory must be left exactly as it is. The chmod version reset the
#    mode on every single save, so a TMUX_ASSISTANT_RESURRECT_DIR the user had
#    deliberately made group-readable got clamped back to 0700 every five minutes by
#    continuum. Nothing else in the suite would have noticed.
esd_keep="$SANDBOX/esd-keep"
mkdir -p "$esd_keep" 2>/dev/null
chmod 750 "$esd_keep" 2>/dev/null
if [ "$(perms_of "$esd_keep")" != "750" ]; then
	skip "an existing state dir keeps its mode" "cannot set modes here"
else
	in_env "HOME=$SANDBOX/esd-home" "source '$LIB'; ensure_assistant_state_dir '$esd_keep'"
	assert_eq "an existing state dir keeps its mode" "750" "$(perms_of "$esd_keep")"
fi

# 4. `chmod` follows symlinks, so the chmod version re-moded the *target* of a link
#    left at $STATE_DIR. Creating-only cannot: the -d test short-circuits on a link
#    to a directory.
esd_target="$SANDBOX/esd-target"
mkdir -p "$esd_target" 2>/dev/null
chmod 755 "$esd_target" 2>/dev/null
ln -s "$esd_target" "$SANDBOX/esd-link" 2>/dev/null || true
if [ -L "$SANDBOX/esd-link" ] && [ "$(perms_of "$esd_target")" = "755" ]; then
	in_env "HOME=$SANDBOX/esd-home" "source '$LIB'; ensure_assistant_state_dir '$SANDBOX/esd-link'"
	assert_eq "a symlinked state dir does not get its target re-moded" "755" \
		"$(perms_of "$esd_target")"
else
	skip "a symlinked state dir does not get its target re-moded" \
		"no working symlinks or modes here (Git Bash)"
fi

# A trailing slash on the override must not confuse the parent computation into
# creating the wrong directory or skipping the leaf.
in_env "HOME=$SANDBOX/esd-home" "source '$LIB'; ensure_assistant_state_dir '$SANDBOX/esd-slash/dir/'"
assert_eq "a trailing slash still creates the leaf" "yes" \
	"$([ -d "$SANDBOX/esd-slash/dir" ] && echo yes || echo no)"

# --- legacy_assistant_state_dirs() ---
#
# The pre-$HOME chain was ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}, and #65 *is* the
# fact that it resolved differently on either side. So the migration scan cannot
# evaluate that chain once in the reader's environment: that finds files only for
# the users whose two sides already agreed — the ones who were never broken — and
# finds nothing for the ones who were. It has to probe every root a pre-upgrade
# hook could have landed on, whether or not this process's environment names it.

echo "== legacy_assistant_state_dirs =="

# Count exact matches of a line in the newline-separated output.
#
# Walked with parameter expansion rather than `read` fed by a here-string: this
# repo contains no `<<<` anywhere (issue #48 -- bash >= 5.1 writes one to a pipe
# before the reader is exec'd, which can block forever on macOS), and a test that
# hangs is no better than a hook that does.
count_line() {
	local needle="$1" rest="$2" nl=$'\n' n=0 line
	while [ -n "$rest" ]; do
		line="${rest%%"$nl"*}"
		if [ "$line" = "$rest" ]; then
			rest=""
		else
			rest="${rest#*"$nl"}"
		fi
		[ "$line" = "$needle" ] && n=$((n + 1))
	done
	echo "$n"
}

out=$(in_env "HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/legacy" "source '$LIB'; legacy_assistant_state_dirs")
assert_eq "\$TMPDIR root is probed" "1" "$(count_line "$SANDBOX/legacy/tmux-assistant-resurrect" "$out")"

# The regression for the blind spot: /tmp stays in the set even though this
# process has a $TMPDIR. A hook that ran with neither variable — a container, a
# daemonised launch — wrote to /tmp, and the reader's own chain would never
# have looked there.
assert_eq "/tmp probed even when \$TMPDIR is set" "1" "$(count_line "/tmp/tmux-assistant-resurrect" "$out")"

out=$(in_env "HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/legacy/" "source '$LIB'; legacy_assistant_state_dirs")
assert_eq "trailing slash on \$TMPDIR collapsed (macOS sets one)" \
	"1" "$(count_line "$SANDBOX/legacy/tmux-assistant-resurrect" "$out")"

# Under the old chain XDG_RUNTIME_DIR *won*, so a file sitting in $TMPDIR was
# unreachable whenever the reader also had XDG_RUNTIME_DIR. Both are probed now.
out=$(in_env "HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/tmp" "XDG_RUNTIME_DIR=$SANDBOX/run" \
	"source '$LIB'; legacy_assistant_state_dirs")
assert_eq "XDG_RUNTIME_DIR root is probed" "1" "$(count_line "$SANDBOX/run/tmux-assistant-resurrect" "$out")"
assert_eq "\$TMPDIR root probed too, not shadowed by XDG_RUNTIME_DIR" \
	"1" "$(count_line "$SANDBOX/tmp/tmux-assistant-resurrect" "$out")"

# The systemd default, for the reader that has no XDG_RUNTIME_DIR (a daemonised
# tmux server) while the hook, run from a login session, did.
out=$(in_env "HOME=$SANDBOX/h1" "source '$LIB'; legacy_assistant_state_dirs")
assert_eq "/run/user/<uid> probed without an XDG_RUNTIME_DIR to name it" \
	"1" "$(count_line "/run/user/$(id -u)/tmux-assistant-resurrect" "$out")"

# Duplicates would migrate the same directory twice and double the log count.
out=$(in_env "HOME=$SANDBOX/h1" "TMPDIR=/tmp" "XDG_RUNTIME_DIR=/tmp/" "source '$LIB'; legacy_assistant_state_dirs")
assert_eq "roots naming the same directory are deduped" "1" "$(count_line "/tmp/tmux-assistant-resurrect" "$out")"

out=$(in_env "HOME=$SANDBOX/h1" "source '$LIB'; TMUX_ASSISTANT_RESURRECT_DIR=/explicit/override legacy_assistant_state_dirs")
assert_eq "no migration when the override pins both sides" "" "$out"

# The current state dir must never appear — the save hook would try to move files
# onto themselves and then rmdir the directory it is about to read.
out=$(in_env "HOME=$SANDBOX/h2" "TMPDIR=$SANDBOX/h2/.local/state" "source '$LIB'; legacy_assistant_state_dirs")
assert_eq "the current state dir is excluded from the probe set" \
	"0" "$(count_line "$SANDBOX/h2/.local/state/tmux-assistant-resurrect" "$out")"

# The macOS gap that probing $TMPDIR alone cannot close: a tmux server started by
# launchd or reached over ssh inherits no $TMPDIR, while the hook that wrote the
# state file did. /var/folders/<hash>/T is keyed on uid rather than on the login
# session, so `getconf DARWIN_USER_TEMP_DIR` resolves the very path the writer used
# — but the fork has to stay off the hot path, which runs every save cycle.
GC_BIN="$SANDBOX/gcstub"
GC_MARKER="$SANDBOX/getconf-was-called"
GC_ANSWER="$SANDBOX/darwin-tmp/"
mkdir -p "$GC_BIN"
cat >"$GC_BIN/getconf" <<STUB
#!/bin/sh
echo called >>"$GC_MARKER"
[ "\$1" = DARWIN_USER_TEMP_DIR ] || exit 1
# Trailing slash, exactly as the real one answers.
printf '%s\n' "$GC_ANSWER"
STUB
chmod +x "$GC_BIN/getconf"

# Prove the stub is reachable and answers before trusting either assertion below:
# the fork-free one is an absence check, and an unreachable stub satisfies it for
# entirely the wrong reason.
gc_probe=$(PATH="$GC_BIN:$PATH" getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
assert_eq "getconf stub answers (guards the two assertions below)" "$GC_ANSWER" "$gc_probe"
rm -f "$GC_MARKER"

# A macOS shell always exports $TMPDIR, so this is the path essentially every real
# save takes. Asserted on every platform: the cost of the fork is not OS-specific.
in_env "HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/legacy" "PATH=$GC_BIN:$PATH" \
	"source '$LIB'; legacy_assistant_state_dirs" >/dev/null
assert_eq "no getconf fork on the hot path when \$TMPDIR is set" "0" \
	"$([ -e "$GC_MARKER" ] && echo 1 || echo 0)"

# The positive case needs a real /var/folders — the second gate on the probe, and
# not something a sandbox can fake. Elsewhere the branch is unreachable by design.
if [ -d /var/folders ]; then
	out=$(env -u TMUX_ASSISTANT_RESURRECT_DIR -u XDG_RUNTIME_DIR -u XDG_STATE_HOME -u TMPDIR \
		"HOME=$SANDBOX/h1" "PATH=$GC_BIN:$PATH" \
		"$UNDER_TEST" -c "source '$LIB'; legacy_assistant_state_dirs" 2>/dev/null)
	assert_eq "no \$TMPDIR on macOS: the per-uid /var/folders temp dir is probed" \
		"1" "$(count_line "$SANDBOX/darwin-tmp/tmux-assistant-resurrect" "$out")"
	assert_eq "/tmp still probed alongside it" "1" "$(count_line "/tmp/tmux-assistant-resurrect" "$out")"
else
	skip "no \$TMPDIR: the per-uid /var/folders temp dir is probed" "not macOS (/var/folders absent)"
fi
rm -f "$GC_MARKER"

# --- opencode plugin parity ---
#
# hooks/opencode-session-track.js resolves the same directory in JavaScript. A
# second implementation is a second chance to drift, so pin them byte for byte.

echo "== opencode plugin parity =="

if command -v node >/dev/null 2>&1; then
	# shellcheck disable=SC2016  # ${...} and `...` here are JavaScript, not shell
	js_expr='const{homedir}=require("os");process.stdout.write(process.env.TMUX_ASSISTANT_RESURRECT_DIR||`${process.env.HOME||homedir()}/.local/state/tmux-assistant-resurrect`)'
	# Keep the expression honest: it must be the literal one the plugin ships.
	plugin_src=$(tr -d ' \n\t' <"$REPO_DIR/hooks/opencode-session-track.js")

	# Running the two implementations against each other only means something where
	# they agree on how to spell a path, and where modes are real. Under Git Bash
	# neither holds: node is a native Windows build, so $HOME comes back as
	# C:\Users\... where bash says /c/Users/..., a leading-slash override resolves
	# against the Git install root, and permissions are emulated. Same directory,
	# different notation — and tmux has no Windows port to disagree on it. The
	# literal-source assertions still run everywhere, which is the half that
	# actually catches drift.
	case "$(uname -s 2>/dev/null)" in
	MINGW* | MSYS* | CYGWIN*) win_paths=1 ;;
	*) win_paths=0 ;;
	esac

	assert_contains "plugin uses \$HOME/.local/state/tmux-assistant-resurrect" \
		"$plugin_src" 'process.env.HOME||homedir()}/.local/state/tmux-assistant-resurrect'

	# The OpenCode 2 tracker is a third copy of the same expression and the same
	# create-only guard. Pin it to the literals the V1 plugin is pinned to.
	plugin2_src=$(tr -d ' \n\t' <"$REPO_DIR/hooks/opencode2/tui.js")
	assert_contains "OpenCode 2 plugin honours TMUX_ASSISTANT_RESURRECT_DIR first" \
		"$plugin2_src" 'process.env.TMUX_ASSISTANT_RESURRECT_DIR||'
	assert_contains "OpenCode 2 plugin uses \$HOME/.local/state/tmux-assistant-resurrect" \
		"$plugin2_src" 'process.env.HOME||homedir()}/.local/state/tmux-assistant-resurrect'
	assert_contains "OpenCode 2 plugin creates the parents without a mode" \
		"$plugin2_src" 'mkdirSync(parent,{recursive:true})'
	assert_contains "OpenCode 2 plugin creates the leaf private" \
		"$plugin2_src" 'mkdirSync(stateDir,{mode:0o700})'

	# The plugin has to match ensure_assistant_state_dir(), not just the path.
	# Node's mkdirSync applies `mode` to every level `recursive` creates — unlike
	# mkdir -p -m — so the one-liner that was here clamped ~/.local and
	# ~/.local/state to 0700 as soon as the state dir moved under $HOME.
	# Pin the *parent* create specifically, not the mere absence of
	# "recursive:true,mode:" anywhere in the file — the EEXIST fallback uses exactly
	# that spelling on the leaf, legitimately and deliberately. The invariant is
	# narrower than "never combine the two": parents must be created with no mode at
	# all, so they land at the umask default instead of being clamped to 0700.
	assert_contains "plugin creates the parents without a mode" \
		"$plugin_src" 'mkdirSync(parent,{recursive:true})'

	# Exercise the real thing rather than a paraphrase: run the plugin's own parent
	# expression and its create-only guard against a sandbox HOME, then check the
	# modes that come out. Two independent reasons to sit this out: native node on
	# Git Bash spells paths differently (as above), and a filesystem that does not
	# honour modes would answer with a number that means nothing.
	if [ "$win_paths" = 1 ] || [ "$MODES_REAL" = 0 ]; then
		skip "plugin creates a private leaf without clamping parents" \
			"native node path notation, or a filesystem that does not honour modes"
	else
		# Extracting by pattern means a refactor could quietly yield nothing, and an
		# empty snippet creates no directory — which would land in the "cannot read
		# modes" skip below and read as an environment limitation rather than as the
		# test having lost its subject. Fail loudly instead.
		plugin_mk=$(sed -n '/if (!existsSync(stateDir))/,/^  }$/p' "$REPO_DIR/hooks/opencode-session-track.js")
		case "$plugin_mk" in
		*mkdirSync*) ;;
		*)
			FAIL=$((FAIL + 1))
			printf '  [FAIL] could not extract the plugin mkdir block — update the sed pattern\n'
			;;
		esac
		# Same pinned umask as the shell case, for the same reason: the parent
		# assertion cannot tell "0700 leaked upwards" from "the developer runs
		# umask 077" unless the umask is fixed. Set in the subshell that runs node,
		# since Node inherits it and has no umask argument to mkdirSync.
		(
			umask 022
			node -e "const{mkdirSync,existsSync}=require('fs');const stateDir=process.argv[1];$plugin_mk" \
				"$SANDBOX/ocdir-home/.local/state/tmux-assistant-resurrect" 2>/dev/null
		)
		oc_leaf=$(perms_of "$SANDBOX/ocdir-home/.local/state/tmux-assistant-resurrect")
		oc_parent=$(perms_of "$SANDBOX/ocdir-home/.local/state")
		if [ "$oc_leaf" = "?" ]; then
			skip "plugin creates a private leaf without clamping parents" "cannot read modes here"
		else
			assert_eq "plugin creates a private leaf" "700" "$oc_leaf"
			assert_eq "plugin does not clamp the parents" "no" \
				"$([ "$oc_parent" = "700" ] && echo yes || echo no)"

			# A slashless TMUX_ASSISTANT_RESURRECT_DIR ("state") has no parent to
			# strip, so without the parent !== trimmed guard the recursive parent
			# create makes the *leaf* at the ambient mode and the private mkdirSync
			# below it only swallows EEXIST — handing back 0755.
			mkdir -p "$SANDBOX/ocslash" 2>/dev/null
			(
				cd "$SANDBOX/ocslash" 2>/dev/null || exit 0
				umask 022
				node -e "const{mkdirSync,existsSync}=require('fs');const stateDir=process.argv[1];$plugin_mk" \
					"ocleaf" 2>/dev/null
			)
			assert_eq "plugin keeps a slashless override private too" "700" \
				"$(perms_of "$SANDBOX/ocslash/ocleaf")"
		fi
	fi

	if [ "$win_paths" = 1 ]; then
		skip "node and bash resolve the identical default" "native node spells Windows paths differently than Git Bash"
	else
		node_out=$(env -u TMUX_ASSISTANT_RESURRECT_DIR -u XDG_RUNTIME_DIR \
			"HOME=$SANDBOX/h1" "TMPDIR=$SANDBOX/writer-tmp" \
			node -e "$js_expr" 2>/dev/null)
		assert_eq "node and bash resolve the identical default" "$reader" "$node_out"

		node_out=$(env "TMUX_ASSISTANT_RESURRECT_DIR=/explicit/override" "HOME=$SANDBOX/h1" \
			node -e "$js_expr" 2>/dev/null)
		assert_eq "node honours the same override" "/explicit/override" "$node_out"
	fi
else
	skip "opencode plugin parity" "node not installed"
fi

# --- migrate_legacy_state_files() ---
#
# Upgrades happen under a live tmux server. Assistants already running fired
# their SessionStart hook against the old path and will not fire it again, so
# without migration the first save after upgrade loses every one of their IDS —
# and continuum overwrites the good sidecar within five minutes.

echo "== migrate_legacy_state_files =="

SAVE="$REPO_DIR/scripts/save-assistant-sessions.sh"

mig_home="$SANDBOX/mig-home"
mig_legacy="$SANDBOX/mig-legacy/tmux-assistant-resurrect"
mig_state="$mig_home/.local/state/tmux-assistant-resurrect"

# migrate_legacy_state_files() *moves* what it finds, and /tmp and /run/user/<uid>
# are now unconditional probe roots — so on a developer machine that has not yet
# upgraded, running these cases would relocate real, live state files into a
# throwaway sandbox HOME. Refuse rather than do that. Ask the resolver itself
# which roots it will touch instead of hardcoding the list here, so a root added
# later cannot slip past the check. CI never has any of them.
mig_hazard=""
mig_probes=$(in_env "HOME=$mig_home" "TMPDIR=$SANDBOX/mig-legacy" "source '$LIB'; legacy_assistant_state_dirs")
mig_nl=$'\n'
while [ -n "$mig_probes" ]; do
	probe="${mig_probes%%"$mig_nl"*}"
	if [ "$probe" = "$mig_probes" ]; then
		mig_probes=""
	else
		mig_probes="${mig_probes#*"$mig_nl"}"
	fi
	[ -n "$probe" ] || continue
	case "$probe" in "$SANDBOX"/*) continue ;; esac
	[ -e "$probe" ] && mig_hazard="$mig_hazard $probe"
done

if [ -n "$mig_hazard" ]; then
	skip "migrate_legacy_state_files (all cases)" \
		"real pre-upgrade state dir(s) present, refusing to move them:$mig_hazard"
else
	fixture "$mig_legacy/claude-4242.json" '{"tool":"claude","session_id":"ses_legacy"}'
	fixture "$mig_legacy/opencode-4243.json" '{"tool":"opencode","session_id":"ses_legacy_oc"}'
	fixture "$mig_state/claude-4244.json" '{"tool":"claude","session_id":"ses_current"}'
	fixture "$mig_legacy/claude-4244.json" '{"tool":"claude","session_id":"ses_legacy_LOSER"}'
	fixture "$mig_legacy/unrelated.txt" 'not ours'
	# Pin both mtimes: which of two files claiming one PID survives is decided by
	# mtime, and fixtures written milliseconds apart can land in the same second.
	touch -t 202601010000 "$mig_legacy/claude-4244.json"
	touch -t 202601020000 "$mig_state/claude-4244.json"

	in_env "HOME=$mig_home" "TMPDIR=$SANDBOX/mig-legacy" "TMUX_RESURRECT_DIR=$SANDBOX/mig-resurrect" \
		"source '$SAVE'; migrate_legacy_state_files" >/dev/null

	assert_eq "legacy claude file moved into the current dir" \
		'{"tool":"claude","session_id":"ses_legacy"}' "$(cat "$mig_state/claude-4242.json" 2>/dev/null)"
	assert_eq "legacy opencode file moved into the current dir" \
		'{"tool":"opencode","session_id":"ses_legacy_oc"}' "$(cat "$mig_state/opencode-4243.json" 2>/dev/null)"
	assert_eq "a newer file already in the current dir is not clobbered" \
		'{"tool":"claude","session_id":"ses_current"}' "$(cat "$mig_state/claude-4244.json" 2>/dev/null)"
	assert_eq "legacy claude file no longer in the old dir" "" "$(ls "$mig_legacy"/claude-*.json 2>/dev/null)"
	assert_eq "files that are not ours are left alone" "not ours" "$(cat "$mig_legacy/unrelated.txt" 2>/dev/null)"

	# The other direction. A destination file can be stale: PIDs are recycled, and
	# $HOME state files now survive the reboot that recycles them. Dropping the
	# legacy file just because *something* sits at the destination loses the only
	# good copy — and reap_stale_state_files() then deletes the stale one it kept,
	# so the session ID is gone entirely. Freshness decides, not position.
	stale_home="$SANDBOX/stale-home"
	stale_legacy="$SANDBOX/stale-legacy/tmux-assistant-resurrect"
	stale_state="$stale_home/.local/state/tmux-assistant-resurrect"
	fixture "$stale_state/claude-4250.json" '{"tool":"claude","session_id":"ses_stale_dest"}'
	fixture "$stale_legacy/claude-4250.json" '{"tool":"claude","session_id":"ses_live_legacy"}'
	touch -t 202601010000 "$stale_state/claude-4250.json"
	touch -t 202601020000 "$stale_legacy/claude-4250.json"

	in_env "HOME=$stale_home" "TMPDIR=$SANDBOX/stale-legacy" "TMUX_RESURRECT_DIR=$SANDBOX/stale-resurrect" \
		"source '$SAVE'; migrate_legacy_state_files" >/dev/null

	assert_eq "a newer legacy file replaces a stale destination" \
		'{"tool":"claude","session_id":"ses_live_legacy"}' "$(cat "$stale_state/claude-4250.json" 2>/dev/null)"

	# Same PID at two pre-upgrade roots. Probe order says nothing about which is
	# current, so the newer one has to win regardless of which is visited first.
	two_home="$SANDBOX/tworoot-home"
	two_state="$two_home/.local/state/tmux-assistant-resurrect"
	fixture "$SANDBOX/tworoot-run/tmux-assistant-resurrect/claude-4260.json" \
		'{"tool":"claude","session_id":"ses_root_older"}'
	fixture "$SANDBOX/tworoot-tmp/tmux-assistant-resurrect/claude-4260.json" \
		'{"tool":"claude","session_id":"ses_root_newer"}'
	touch -t 202601010000 "$SANDBOX/tworoot-run/tmux-assistant-resurrect/claude-4260.json"
	touch -t 202601020000 "$SANDBOX/tworoot-tmp/tmux-assistant-resurrect/claude-4260.json"
	mkdir -p "$two_state" 2>/dev/null

	# XDG_RUNTIME_DIR is probed before TMPDIR, so the older file is seen first.
	in_env "HOME=$two_home" "TMPDIR=$SANDBOX/tworoot-tmp" "XDG_RUNTIME_DIR=$SANDBOX/tworoot-run" \
		"TMUX_RESURRECT_DIR=$SANDBOX/tworoot-resurrect" \
		"source '$SAVE'; migrate_legacy_state_files" >/dev/null

	assert_eq "newest wins when two legacy roots claim the same PID" \
		'{"tool":"claude","session_id":"ses_root_newer"}' "$(cat "$two_state/claude-4260.json" 2>/dev/null)"

	# The save script runs under `set -euo pipefail`, so a bare failing mv would
	# abort it before assistant-sessions.json is written — losing every pane's
	# session ID over one unmovable file. Hence the `|| true` there, which this
	# pins.
	#
	# The failure is injected per file rather than by locking the whole state dir,
	# which would stop the *second* file too — leaving nothing to distinguish "the
	# loop continued" from "the loop unwound". So put an unwritable directory
	# exactly where the first file's destination goes. A plain directory at $dest
	# would not fail (mv moves the file into it); one with no write permission
	# does, and only for that file.
	err_home="$SANDBOX/mverr-home"
	err_legacy="$SANDBOX/mverr-legacy/tmux-assistant-resurrect"
	err_state="$err_home/.local/state/tmux-assistant-resurrect"
	fixture "$err_legacy/claude-4270.json" '{"tool":"claude","session_id":"ses_unmovable"}'
	fixture "$err_legacy/claude-4271.json" '{"tool":"claude","session_id":"ses_alsostuck"}'
	mkdir -p "$err_state/claude-4270.json" 2>/dev/null
	# $dest exists, so the newest-wins branch runs first and would delete the source
	# as an older duplicate before ever reaching the mv. Backdate the *destination*
	# rather than post-dating the source: a fixed future stamp on the source stops
	# being in the future once the calendar reaches it, and the test would quietly
	# invert. Backdating cannot expire. Ordered before the chmod so the utimes call
	# is not the thing being tested.
	touch -t 200001010000 "$err_state/claude-4270.json" 2>/dev/null
	chmod 500 "$err_state/claude-4270.json" 2>/dev/null

	# Confirm the injection actually bites before asserting on it, rather than
	# assuming: chmod does not restrain root and is largely a no-op on Git Bash,
	# and an assertion that a write "failed" because the setup silently did
	# nothing is worth less than no assertion at all.
	if (: >"$err_state/claude-4270.json/.probe") 2>/dev/null; then
		rm -f "$err_state/claude-4270.json/.probe"
		skip "failing mv does not abort the save" \
			"cannot make a directory unwritable here (root, or non-POSIX permissions)"
	else
		out=$(in_env "HOME=$err_home" "TMPDIR=$SANDBOX/mverr-legacy" \
			"TMUX_RESURRECT_DIR=$SANDBOX/mverr-resurrect" \
			"source '$SAVE'; migrate_legacy_state_files; echo rc=\$?")
		assert_eq "a failing mv does not abort the save under set -e" "rc=0" "$out"
		assert_eq "the unmovable file is left in place to retry" \
			'{"tool":"claude","session_id":"ses_unmovable"}' "$(cat "$err_legacy/claude-4270.json" 2>/dev/null)"
		# Landing at the *destination* is what proves the loop kept going past the
		# failure rather than unwinding; still sitting in the legacy dir would not.
		assert_eq "later files in the same batch are still processed" \
			'{"tool":"claude","session_id":"ses_alsostuck"}' "$(cat "$err_state/claude-4271.json" 2>/dev/null)"
	fi
	chmod 700 "$err_state/claude-4270.json" 2>/dev/null

	# THE regression for the migration blind spot. The reader has XDG_RUNTIME_DIR
	# set, so the old chain resolved its legacy path to that and only that. The
	# file here was written by a hook that had no XDG_RUNTIME_DIR and fell through
	# to $TMPDIR — the #65 divergence exactly. Resolving the chain once in the
	# reader's environment misses it, and that assistant stays ID-less until it is
	# restarted, with no log line to say why.
	shadow_home="$SANDBOX/shadow-home"
	shadow_tmp="$SANDBOX/shadow-tmp/tmux-assistant-resurrect"
	shadow_run="$SANDBOX/shadow-run/tmux-assistant-resurrect"
	shadow_state="$shadow_home/.local/state/tmux-assistant-resurrect"
	fixture "$shadow_tmp/claude-5150.json" '{"tool":"claude","session_id":"ses_shadowed"}'
	mkdir -p "$shadow_run" "$shadow_state" 2>/dev/null

	in_env "HOME=$shadow_home" "TMPDIR=$SANDBOX/shadow-tmp" "XDG_RUNTIME_DIR=$SANDBOX/shadow-run" \
		"TMUX_RESURRECT_DIR=$SANDBOX/shadow-resurrect" \
		"source '$SAVE'; migrate_legacy_state_files" >/dev/null

	assert_eq "file in a root the reader's own chain would not have picked is still migrated" \
		'{"tool":"claude","session_id":"ses_shadowed"}' "$(cat "$shadow_state/claude-5150.json" 2>/dev/null)"

	# /tmp/tmux-assistant-resurrect sits under a world-writable parent and is not
	# scoped by uid: pre-fix, whoever got there first owned it. A symlink standing
	# where that directory was expected must not be followed — the files behind it
	# are by definition not ours to move.
	sym_target="$SANDBOX/sym-target"
	fixture "$sym_target/claude-6161.json" '{"tool":"claude","session_id":"ses_not_ours"}'
	sym_home="$SANDBOX/sym-home"
	mkdir -p "$SANDBOX/sym-legacy" "$sym_home/.local/state/tmux-assistant-resurrect" 2>/dev/null
	ln -s "$sym_target" "$SANDBOX/sym-legacy/tmux-assistant-resurrect" 2>/dev/null

	# Without developer mode or MSYS=winsymlinks:nativestrict, Git Bash copies the
	# directory instead of linking to it, and `[ -L ]` sees nothing to refuse. Assert
	# the injection took before trusting a guard that has nothing to guard against —
	# both assertions below would otherwise pass for the wrong reason.
	if [ -L "$SANDBOX/sym-legacy/tmux-assistant-resurrect" ]; then
		in_env "HOME=$sym_home" "TMPDIR=$SANDBOX/sym-legacy" "TMUX_RESURRECT_DIR=$SANDBOX/sym-resurrect" \
			"source '$SAVE'; migrate_legacy_state_files" >/dev/null

		assert_eq "a symlinked legacy dir is not followed" \
			'{"tool":"claude","session_id":"ses_not_ours"}' "$(cat "$sym_target/claude-6161.json" 2>/dev/null)"
		assert_eq "nothing migrated out of a symlinked legacy dir" \
			"" "$(ls "$sym_home/.local/state/tmux-assistant-resurrect"/claude-*.json 2>/dev/null)"
	else
		skip "a symlinked legacy dir is not followed" "ln -s did not produce a symlink here"
	fi

	# Migration is a no-op, not an error, when there is no legacy directory at all
	# — the common case for every fresh install. Inside the guard despite moving
	# nothing: the trailing best-effort rmdir still reaches a real, empty probe
	# root, and a test has no business removing directories outside its sandbox.
	IN_ENV_ERR="$SANDBOX/nomig.err"
	out=$(in_env "HOME=$SANDBOX/nomig-home" "TMPDIR=$SANDBOX/nonexistent" \
		"TMUX_RESURRECT_DIR=$SANDBOX/nomig-resurrect" \
		"source '$SAVE'; migrate_legacy_state_files; echo rc=\$?")
	assert_eq "no legacy dir is a clean no-op" "rc=0" "$(or_stderr "$out" "$IN_ENV_ERR")"
	IN_ENV_ERR=""
fi

# --- reap_stale_state_files() ---
#
# The SessionEnd hook never runs on SIGKILL, OOM or a closed terminal. Under the
# old $TMPDIR default those leftovers went away at reboot; $HOME does not, so the
# save hook has to sweep them itself.

echo "== reap_stale_state_files =="

sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null

reap_home="$SANDBOX/reap-home"
reap_state="$reap_home/.local/state/tmux-assistant-resurrect"
# Every assertion in this section but two is an absence check, so the fixtures
# have to be verified into existence first — see fixture().
fixture "$reap_state/claude-$DEAD_PID.json" '{}'
fixture "$reap_state/claude-$$.json" '{}'
fixture "$reap_state/claude-0.json" '{}'
fixture "$reap_state/opencode-not-a-number.json" '{}'
fixture "$reap_state/assistant-sessions.json" '{}'

in_env "HOME=$reap_home" "TMUX_RESURRECT_DIR=$SANDBOX/reap-resurrect" \
	"source '$SAVE'; reap_stale_state_files" >/dev/null
reap_log=$(cat "$SANDBOX/reap-resurrect/assistant-save.log" 2>/dev/null)

assert_eq "dead PID reaped" "" "$(ls "$reap_state/claude-$DEAD_PID.json" 2>/dev/null)"
assert_eq "live PID kept" "$reap_state/claude-$$.json" "$(ls "$reap_state/claude-$$.json" 2>/dev/null)"
# kill -0 0 signals the caller's own process group and always succeeds, so
# without the numeric guard a corrupt pid-0 file would survive forever.
assert_eq "pid 0 reaped despite kill -0 succeeding" "" "$(ls "$reap_state/claude-0.json" 2>/dev/null)"
assert_eq "non-numeric PID reaped" "" "$(ls "$reap_state/opencode-not-a-number.json" 2>/dev/null)"
assert_eq "unrelated json left alone" "$reap_state/assistant-sessions.json" \
	"$(ls "$reap_state/assistant-sessions.json" 2>/dev/null)"
assert_contains "reaping is logged" "$reap_log" "reaped 3 stale state file(s)"

# Recycled PID: after a reboot every PID is reused, and $HOME state files now
# survive that. A leftover file matching an unrelated live process would restore
# a stranger's conversation into the pane. The hook writes just after the
# assistant starts, so a file older than the process claiming it is stale.
if [ -n "$(env -u TMUX_ASSISTANT_RESURRECT_DIR "HOME=$reap_home" "TMUX_RESURRECT_DIR=$SANDBOX/reap-resurrect" "$UNDER_TEST" -c "source '$SAVE'; get_process_start_epoch $$" 2>/dev/null)" ]; then
	fixture "$reap_state/claude-$$.json" '{}'
	touch -t 200001010000 "$reap_state/claude-$$.json"
	in_env "HOME=$reap_home" "TMUX_RESURRECT_DIR=$SANDBOX/reap-resurrect" \
		"source '$SAVE'; reap_stale_state_files" >/dev/null
	assert_eq "live PID with a file older than the process is reaped (recycled PID)" \
		"" "$(ls "$reap_state/claude-$$.json" 2>/dev/null)"
else
	skip "recycled-PID reaping" "process start time unavailable on this platform"
fi

# `rm -f` is not infallible — it still fails on a file it cannot unlink, e.g. in a
# state dir that has gone read-only. Under `set -e` a bare one would abort the save
# before assistant-sessions.json is written, losing every pane's session ID over a
# single undeletable leftover: the same catastrophic shape the `mv` in
# migrate_legacy_state_files() is guarded against.
rmerr_home="$SANDBOX/rmerr-home"
rmerr_state="$rmerr_home/.local/state/tmux-assistant-resurrect"
fixture "$rmerr_state/claude-$DEAD_PID.json" '{}'
chmod 500 "$rmerr_state" 2>/dev/null

# Confirm the injection bites before asserting on it — chmod does not restrain root
# and is largely a no-op on Git Bash, and "the rm failed" is worthless as a claim if
# the setup silently made it succeed.
if (: >"$rmerr_state/.probe") 2>/dev/null; then
	rm -f "$rmerr_state/.probe"
	skip "a failing rm does not abort the reap" "cannot make a directory unwritable here"
else
	out=$(in_env "HOME=$rmerr_home" "TMUX_RESURRECT_DIR=$SANDBOX/rmerr-resurrect" \
		"source '$SAVE'; reap_stale_state_files; echo rc=\$?")
	assert_eq "a failing rm does not abort the reap under set -e" "rc=0" "$out"
	assert_eq "the undeletable file is left in place" "yes" \
		"$([ -f "$rmerr_state/claude-$DEAD_PID.json" ] && echo yes || echo no)"
	# The count drives the log line, so an unconditional increment would have it
	# claim work that did not happen. Hoisted out of the assertion: bash 3.2 ends a
	# command substitution at the first `)`, which a case pattern always has.
	rmerr_log=$(cat "$SANDBOX/rmerr-resurrect/assistant-save.log" 2>/dev/null)
	case "$rmerr_log" in
	*reaped*) rmerr_claimed=yes ;;
	*) rmerr_claimed=no ;;
	esac
	assert_eq "a file that could not be removed is not logged as reaped" "no" "$rmerr_claimed"
fi
chmod 700 "$rmerr_state" 2>/dev/null

# An empty (or absent) state dir must not trip the glob-with-no-match case.
IN_ENV_ERR="$SANDBOX/emptyreap.err"
out=$(in_env "HOME=$SANDBOX/emptyreap-home" "TMUX_RESURRECT_DIR=$SANDBOX/emptyreap-resurrect" \
	"source '$SAVE'; reap_stale_state_files; echo rc=\$?")
assert_eq "empty state dir is a clean no-op" "rc=0" "$(or_stderr "$out" "$IN_ENV_ERR")"
IN_ENV_ERR=""

# --- missing_session_hint() ---
#
# "no session ID available" alone cannot distinguish "the hook never ran" from
# "the hook wrote somewhere this process cannot see" — the #65 failure. The log
# has to name the path it looked in.

echo "== missing_session_hint =="

hint_dir="$SANDBOX/hint-state"
mkdir -p "$hint_dir" 2>/dev/null

out=$(env "TMUX_ASSISTANT_RESURRECT_DIR=$hint_dir" "HOME=$SANDBOX/h1" \
	"TMUX_RESURRECT_DIR=$SANDBOX/hint-resurrect" \
	"$UNDER_TEST" -c "source '$SAVE'; missing_session_hint claude 4242" 2>/dev/null)
assert_contains "empty state dir points at the resolved path" "$out" "$hint_dir/claude-4242.json"
assert_contains "empty state dir names the override to fix it with" "$out" "TMUX_ASSISTANT_RESURRECT_DIR"

fixture "$hint_dir/claude-9999.json" '{}'
out=$(env "TMUX_ASSISTANT_RESURRECT_DIR=$hint_dir" "HOME=$SANDBOX/h1" \
	"TMUX_RESURRECT_DIR=$SANDBOX/hint-resurrect" \
	"$UNDER_TEST" -c "source '$SAVE'; missing_session_hint claude 4242" 2>/dev/null)
assert_contains "other state files present: report just the missing file" "$out" "no $hint_dir/claude-4242.json"

fixture "$hint_dir/claude-4242.json" '{"tool":"claude"}'
out=$(env "TMUX_ASSISTANT_RESURRECT_DIR=$hint_dir" "HOME=$SANDBOX/h1" \
	"TMUX_RESURRECT_DIR=$SANDBOX/hint-resurrect" \
	"$UNDER_TEST" -c "source '$SAVE'; missing_session_hint claude 4242" 2>/dev/null)
assert_contains "file present but no id: say so" "$out" "holds no session_id"

# Tools without a state file (codex/pi/omp/grok/copilot) must not be told to look
# for one that never existed.
out=$(env "TMUX_ASSISTANT_RESURRECT_DIR=$hint_dir" "HOME=$SANDBOX/h1" \
	"TMUX_RESURRECT_DIR=$SANDBOX/hint-resurrect" \
	"$UNDER_TEST" -c "source '$SAVE'; missing_session_hint codex 4242" 2>/dev/null)
assert_eq "state-file-less tools get no state-file hint" "(no session ID in args)" "$out"

echo
echo "state-dir unit tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
