#!/usr/bin/env bash
# Hermetic unit tests for GitHub Copilot CLI session discovery.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
# COPILOT_HOME is Copilot's own override for the whole ~/.copilot path, so the
# tests drive the same variable a user would (no test-only path hook).
export COPILOT_HOME="$SANDBOX/copilot-home"
# Distinct name: the sourced save script owns a global STATE_DIR of its own.
COPILOT_STATE="$COPILOT_HOME/session-state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR" \
	"$COPILOT_STATE" "$SANDBOX/bin"

# Keep CLI-flag discovery deterministic and exercise the real help parser.
# Spellings copied verbatim from `copilot --help` (1.0.78) so the real parsers
# are exercised: `<value>` = one value, `[=name...]` = variadic.
HELP_CALLS="$SANDBOX/help-calls"
: >"$HELP_CALLS"
cat >"$SANDBOX/bin/copilot" <<EOF
#!/usr/bin/env bash
echo call >>"$HELP_CALLS"
cat <<'HELP'
  --add-dir <directory>                 Add a directory to the allowed list
  --agent <agent>                       Specify a custom agent to use
  --allow-tool[=tools...]               Tools the CLI has permission to use
  --allow-url[=urls...]                 Allow access to specific URLs or domains
  --available-tools[=tools...]          Only these tools will be available
  --connect[=sessionId]                 Connect to a remote session
  --continue                            Resume the most recent session
  --deny-tool[=tools...]                Tools the CLI does not have permission
  --deny-url[=urls...]                  Deny access to specific URLs or domains
  --excluded-tools[=tools...]           These tools will not be available
  -i, --interactive <prompt>            Start interactive mode and execute prompt
  -n, --name <name>                     Set a name for the new session
  -p, --prompt <prompt>                 Submit one non-interactive prompt
  -r, --resume[=value]                  Resume a previous session
  --secret-env-vars[=vars...]           Environment variable names to redact
  --session-id <id>                     Use a specific session ID
HELP
EOF
chmod +x "$SANDBOX/bin/copilot"
export PATH="$SANDBOX/bin:$PATH"

source "$REPO_DIR/scripts/lib-detect.sh"
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1

PASS=0
FAIL=0

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected: [%s]\n        actual:   [%s]\n' \
			"$desc" "$expected" "$actual"
	fi
}

assert_missing() {
	local desc="$1" path="$2"
	if [ ! -e "$path" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        unexpected path: %s\n' "$desc" "$path"
	fi
}

SID_CURRENT="550e8400-e29b-41d4-a716-446655440000"
SID_STALE="11111111-2222-4333-8444-555555555555"

# Mirror the real layout: session-state/<uuid>/inuse.<pid>.lock, content = PID.
# See test/copilot-contract-test.sh, which pins this against the real binary.
# A *resumable* session: the lock names the owning PID, and session.db marks it
# as having real content. Copilot writes the lock at TUI startup but session.db
# only once the conversation has content, and `--resume` rejects a session
# without it. See test/copilot-contract-test.sh.
make_lock() {
	local sid="$1" pid="$2"
	mkdir -p "$COPILOT_STATE/$sid"
	printf '%s\n' "$pid" >"$COPILOT_STATE/$sid/inuse.$pid.lock"
	: >"$COPILOT_STATE/$sid/session.db"
}

echo "== detect_tool =="
assert_eq "bare copilot" "copilot" "$(detect_tool "copilot")"
assert_eq "copilot with path" "copilot" \
	"$(detect_tool "/opt/homebrew/bin/copilot --resume=$SID_CURRENT")"
assert_eq "node launcher with copilot script" "copilot" \
	"$(detect_tool "node /opt/homebrew/bin/copilot --no-auto-update")"
assert_eq "no false positive copilot-helper" "" \
	"$(detect_tool "/usr/local/bin/copilot-helper --watch")"
assert_eq "unrelated argument value" "" \
	"$(detect_tool "python3 worker.py --profile copilot")"

echo "== inuse lock lookup =="
make_lock "$SID_CURRENT" 1001
assert_eq "resolves UUID from inuse.<pid>.lock" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot")"
assert_eq "live lock wins over stale launcher argv" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot --session-id=$SID_STALE")"

# Copilot can leave the old session's lock behind after an in-process /resume.
# The newest valid lock for the PID is the current session.
#
# Uses a PID that does not exist so the stale-lock guard stays out of the way:
# these locks are back-dated to force a same-second mtime, and for a *live* PID
# that would (correctly) look older than the process and be rejected. PID 1006
# happens to be free in a container but taken on macOS, which made this fail
# there only.
SID_SWITCH_OLD="77777777-8888-4999-8aaa-bbbbbbbbbbbb"
SID_SWITCH_NEW="88888888-9999-4aaa-8bbb-cccccccccccc"
make_lock "$SID_SWITCH_OLD" 424242
touch -t 202601010000.00 "$COPILOT_STATE/$SID_SWITCH_OLD/inuse.424242.lock"
# Distinct ctime: the tie-break reads ctime, and a filesystem with coarse
# timestamps can otherwise give both locks the same one under load.
sleep 1
make_lock "$SID_SWITCH_NEW" 424242
# Give both locks the same whole-second mtime. Their high-resolution ctime
# still records creation order and must break the tie.
touch -t 202601010000.00 "$COPILOT_STATE/$SID_SWITCH_NEW/inuse.424242.lock"
assert_eq "newest lock wins when mtimes share the same second" "$SID_SWITCH_NEW" \
	"$(get_copilot_session 424242 "copilot")"

# The lookup is keyed on PID, so sessions sharing a cwd stay unambiguous and a
# lock belonging to a different Copilot is never picked up.
make_lock "$SID_STALE" 1002
assert_eq "another PID's lock is not borrowed" "$SID_STALE" \
	"$(get_copilot_session 1002 "copilot")"
assert_eq "PID with no lock resolves nothing" "" \
	"$(get_copilot_session 1003 "copilot" 0)"

echo "== resumability gate =="
# A freshly opened TUI has a lock but no session.db. Saving that UUID would make
# restore replay `--resume=<uuid>` and print "No session, task, or name matched"
# into the user's pane, so it must resolve to nothing until content exists.
SID_EMPTY="55555555-6666-4777-8888-999999999999"
mkdir -p "$COPILOT_STATE/$SID_EMPTY"
printf '%s\n' 1007 >"$COPILOT_STATE/$SID_EMPTY/inuse.1007.lock"
assert_eq "session with no session.db is not saved" "" \
	"$(get_copilot_session 1007 "copilot" 0)"
: >"$COPILOT_STATE/$SID_EMPTY/session.db"
assert_eq "same session resolves once session.db appears" "$SID_EMPTY" \
	"$(get_copilot_session 1007 "copilot" 0)"

echo "== lock integrity =="
mkdir -p "$COPILOT_STATE/not-a-uuid"
printf '%s\n' 1004 >"$COPILOT_STATE/not-a-uuid/inuse.1004.lock"
assert_eq "non-UUID session directory is ignored" "" \
	"$(get_copilot_session 1004 "copilot" 0)"

SID_MISMATCH="22222222-3333-4444-8555-666666666666"
mkdir -p "$COPILOT_STATE/$SID_MISMATCH"
printf '%s\n' 9999 >"$COPILOT_STATE/$SID_MISMATCH/inuse.1005.lock"
assert_eq "lock whose content disagrees with its name is ignored" "" \
	"$(get_copilot_session 1005 "copilot" 0)"

echo "== stale lock from a recycled PID =="
# A SIGKILLed Copilot leaves its lock behind; if the PID is later recycled, the
# stale lock must not map the new process onto the dead session. This needs a
# PID that is genuinely alive so get_process_start_epoch() returns something to
# compare against — the test shell itself is the simplest such process.
LIVE_PID=$$
SID_RECYCLED="33333333-4444-4555-8666-777777777777"
make_lock "$SID_RECYCLED" "$LIVE_PID"
assert_eq "lock newer than the process is accepted" "$SID_RECYCLED" \
	"$(get_copilot_session "$LIVE_PID" "copilot" 0)"
touch -t 200001010000 "$COPILOT_STATE/$SID_RECYCLED/inuse.$LIVE_PID.lock"
assert_eq "lock predating the process is rejected as stale" "" \
	"$(get_copilot_session "$LIVE_PID" "copilot" 0)"
rm -rf "${COPILOT_STATE:?}/$SID_RECYCLED"

echo "== argv fallback =="
assert_eq "--session-id=<uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --session-id=$SID_CURRENT")"
assert_eq "--session-id <uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --session-id $SID_CURRENT")"
assert_eq "--resume=<uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --resume=$SID_CURRENT")"
assert_eq "-r <uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot -r $SID_CURRENT")"
assert_eq "reject non-UUID resume selector" "" \
	"$(get_copilot_session 3001 "copilot --resume latest-session")"
assert_eq "deferred argv fallback can be disabled" "" \
	"$(get_copilot_session 3001 "copilot --resume=$SID_CURRENT" 0)"

# `copilot --session-id <uuid>` puts a UUID in argv at launch, long before the
# session can be resumed. The fallback must apply the same gate as the lock path
# or it re-introduces exactly the unresumable saves the gate exists to prevent.
SID_ARGV_EMPTY="99999999-aaaa-4bbb-8ccc-dddddddddddd"
mkdir -p "$COPILOT_STATE/$SID_ARGV_EMPTY"
assert_eq "argv fallback declines a session with no session.db" "" \
	"$(get_copilot_session 3002 "copilot --session-id=$SID_ARGV_EMPTY")"
: >"$COPILOT_STATE/$SID_ARGV_EMPTY/session.db"
assert_eq "argv fallback accepts it once session.db appears" "$SID_ARGV_EMPTY" \
	"$(get_copilot_session 3002 "copilot --session-id=$SID_ARGV_EMPTY")"

echo "== state root resolution =="
# Deprecated but still honored: --config-dir moves the whole state root, and a
# session launched with it writes nothing under ~/.copilot.
SID_CFGDIR="44444444-5555-4666-8777-888888888888"
CFG_ROOT="$SANDBOX/alt-config"
mkdir -p "$CFG_ROOT/session-state/$SID_CFGDIR"
printf '%s\n' 1006 >"$CFG_ROOT/session-state/$SID_CFGDIR/inuse.1006.lock"
: >"$CFG_ROOT/session-state/$SID_CFGDIR/session.db"
assert_eq "--config-dir <path> relocates the state root" \
	"$CFG_ROOT/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir $CFG_ROOT --allow-all")"
assert_eq "--config-dir=<path> relocates the state root" \
	"$CFG_ROOT/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir=$CFG_ROOT")"
# `ps` flattens the quoting, so a root with spaces arrives as several tokens.
CFG_SPACED="$SANDBOX/My State Dir"
SID_SPACED="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
mkdir -p "$CFG_SPACED/session-state/$SID_SPACED"
printf '%s\n' 1008 >"$CFG_SPACED/session-state/$SID_SPACED/inuse.1008.lock"
: >"$CFG_SPACED/session-state/$SID_SPACED/session.db"
assert_eq "--config-dir with spaces is not truncated" \
	"$CFG_SPACED/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir $CFG_SPACED --allow-all")"
assert_eq "lock is found under a spaced --config-dir" "$SID_SPACED" \
	"$(get_copilot_session 1008 "copilot --config-dir $CFG_SPACED" 0)"

assert_eq "lock is found under --config-dir" "$SID_CFGDIR" \
	"$(get_copilot_session 1006 "copilot --config-dir $CFG_ROOT" 0)"
assert_eq "same PID resolves nothing without --config-dir" "" \
	"$(get_copilot_session 1006 "copilot" 0)"

assert_eq "COPILOT_HOME overrides the whole ~/.copilot path" \
	"$COPILOT_HOME/session-state" "$(copilot_session_state_dir)"
assert_eq "defaults to ~/.copilot when COPILOT_HOME is unset" \
	"$HOME/.copilot/session-state" \
	"$(COPILOT_HOME='' copilot_session_state_dir)"
assert_eq "missing state root resolves nothing, quietly" "" \
	"$(COPILOT_HOME="$SANDBOX/absent" get_copilot_session 1001 "copilot" 0)"

# A tmux hook does not inherit the interactive shell's environment, so a
# COPILOT_HOME exported from a profile is invisible to the save hook. On
# Linux/WSL it is read back from the Copilot process's own environment.
# Driven through a fake /proc so it is deterministic and platform-independent:
# an earlier version kept a real background process alive and raced the suite.
PROC_ROOT="$SANDBOX/proc-home"
FAKE_PROC="$SANDBOX/fake-proc"
SID_PROCENV="66666666-7777-4888-8999-aaaaaaaaaaaa"
mkdir -p "$PROC_ROOT/session-state/$SID_PROCENV" "$FAKE_PROC/4242"
printf '%s\n' 4242 >"$PROC_ROOT/session-state/$SID_PROCENV/inuse.4242.lock"
: >"$PROC_ROOT/session-state/$SID_PROCENV/session.db"
printf 'PATH=/usr/bin\0COPILOT_HOME=%s\0SHELL=/bin/bash\0' "$PROC_ROOT" \
	>"$FAKE_PROC/4242/environ"
assert_eq "COPILOT_HOME is read from the Copilot process environment" \
	"$SID_PROCENV" \
	"$(COPILOT_PROC_ROOT="$FAKE_PROC" COPILOT_HOME='' get_copilot_session 4242 "copilot" 0)"
assert_eq "--config-dir still outranks the process environment" \
	"$CFG_ROOT/session-state" \
	"$(COPILOT_PROC_ROOT="$FAKE_PROC" copilot_session_state_dir "copilot --config-dir $CFG_ROOT" 4242)"
assert_eq "process environment without COPILOT_HOME falls through" \
	"$HOME/.copilot/session-state" \
	"$(COPILOT_PROC_ROOT="$SANDBOX/absent-proc" COPILOT_HOME='' copilot_session_state_dir "copilot" 4242)"

# The save sidecar must retain the resolved state root. Discovery alone is not
# enough: restore needs the same root to find the UUID again.
ROOT_PARTS="$SANDBOX/root-parts"
ROOT_CACHE="$SANDBOX/root-cache"
: >"$ROOT_PARTS"
: >"$ROOT_CACHE"
root_candidates=$(printf 'copilot\0371008\037copilot --config-dir %s\n' "$CFG_SPACED")
resolve_pane_candidates \
	"test:1.2" "/tmp" "/dev/ttys002" "$root_candidates" $'\037' 0 \
	"$ROOT_CACHE" "$ROOT_PARTS"
assert_eq "resolved Copilot home is persisted for restore" "$CFG_SPACED" \
	"$(awk -F '\t' 'NR == 1 { print $9 }' "$ROOT_PARTS")"

# A process-only COPILOT_HOME must be read once and reused. If Copilot exits
# after discovery, a second /proc read would fall back to the hook's default
# root and pair the correct UUID with the wrong home.
RACE_ROOT="$SANDBOX/race-home"
RACE_SID="bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
RACE_CALLS="$SANDBOX/race-home-calls"
RACE_PARTS="$SANDBOX/race-parts"
RACE_CACHE="$SANDBOX/race-cache"
mkdir -p "$RACE_ROOT/session-state/$RACE_SID"
printf '%s\n' 4243 >"$RACE_ROOT/session-state/$RACE_SID/inuse.4243.lock"
: >"$RACE_ROOT/session-state/$RACE_SID/session.db"
printf '0\n' >"$RACE_CALLS"
: >"$RACE_PARTS"
: >"$RACE_CACHE"
original_copilot_home_fn=$(declare -f _copilot_home_from_process)
_copilot_home_from_process() {
	local calls
	calls=$(cat "$RACE_CALLS")
	calls=$((calls + 1))
	printf '%s\n' "$calls" >"$RACE_CALLS"
	[ "$calls" -eq 1 ] && printf '%s' "$RACE_ROOT"
}
race_candidates=$(printf 'copilot\0374243\037copilot\n')
resolve_pane_candidates \
	"test:1.3" "/tmp" "/dev/ttys003" "$race_candidates" $'\037' 0 \
	"$RACE_CACHE" "$RACE_PARTS"
eval "$original_copilot_home_fn"
assert_eq "process-only Copilot home is resolved once" "1" "$(cat "$RACE_CALLS")"
assert_eq "process exit cannot replace the saved Copilot home" "$RACE_ROOT" \
	"$(awk -F '\t' 'NR == 1 { print $9 }' "$RACE_PARTS")"
assert_eq "tcsh state-root quoting escapes history expansion" "'/tmp/a\\!b'" \
	"$(shell_quote tcsh '/tmp/a!b')"
assert_eq "tcsh state-root quoting preserves embedded quotes" \
	"'/tmp/a'\\''b\\!c'" "$(shell_quote tcsh "/tmp/a'b!c")"

echo "== unresolved candidate is non-fatal under set -e =="
UNRESOLVED_PARTS="$SANDBOX/unresolved-parts"
UNRESOLVED_CACHE="$SANDBOX/unresolved-cache"
: >"$UNRESOLVED_PARTS"
: >"$UNRESOLVED_CACHE"
if (
	set -e
	resolve_pane_candidates \
		"test:1.1" "/tmp" "/dev/ttys001" \
		$'copilot\0379999\037copilot' $'\037' 0 \
		"$UNRESOLVED_CACHE" "$UNRESOLVED_PARTS"
); then
	PASS=$((PASS + 1))
	printf '  [pass] unresolved Copilot candidate does not abort save\n'
else
	FAIL=$((FAIL + 1))
	printf '  [FAIL] unresolved Copilot candidate aborted save\n'
fi
assert_eq "unresolved candidate emits no session entry" "0" \
	"$(wc -l <"$UNRESOLVED_PARTS" | tr -d ' ')"

echo "== extract_cli_args =="
unset _SESSION_FLAGS_copilot
assert_eq "strip session selectors and one-shot prompt" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --session-id=$SID_CURRENT --autopilot -p run once --model gpt-5.6-sol")"
assert_eq "multi-word long prompt cannot leak positional args" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --prompt add a health check endpoint --autopilot")"
assert_eq "flags before equals-form prompt are preserved" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot --prompt=add a health check")"
assert_eq "multi-word interactive prompt cannot leak positional args" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --interactive add a health check --autopilot")"
assert_eq "short interactive prompt cannot leak positional args" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot -i fix the login bug --model ignored")"
assert_eq "strip resume and connect selectors" "--no-remote" \
	"$(extract_cli_args copilot "copilot --connect=remote --no-remote --resume $SID_CURRENT")"
assert_eq "preserve operational flags" \
	"--allow-all --autopilot --max-autopilot-continues 20" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot --max-autopilot-continues 20")"

# `copilot --name x --resume=<id>` is rejected outright ("cannot be used with"),
# so a named session must lose its name to be resumable at all.
assert_eq "strip --name so it cannot collide with --resume" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name nightly-triage --allow-all")"
assert_eq "strip short -n too" "--allow-all" \
	"$(extract_cli_args copilot "copilot -n nightly-triage --allow-all")"

echo "== flattened multi-word values =="
# Copilot takes zero positional arguments, so replaying the tail of a value
# whose quoting `ps` erased makes it exit with "too many arguments". Options
# that cannot be reconstructed are dropped instead.
assert_eq "drop an option whose value lost its quoting" "--allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir /tmp/My Project --allow-all")"
assert_eq "single-token value is unambiguous and kept" \
	"--add-dir /tmp/project --allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir /tmp/project --allow-all")"
assert_eq "variadic options keep all their values" \
	"--allow-tool shell write --allow-all" \
	"$(extract_cli_args copilot "copilot --allow-tool shell write --allow-all")"
assert_eq "multi-word --name leaves no stray positional" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name my nightly run --allow-all")"
assert_eq "flattened value at end of argv" "--autopilot" \
	"$(extract_cli_args copilot "copilot --autopilot --agent my custom agent")"

# `--name="my feature"` reaches ps as `--name=my feature`: the bare run is only
# one token, but the equals already bounded the value, so the extra word can
# only be a lost fragment.
assert_eq "drop equals-form option whose value lost its quoting" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name=my feature --allow-all")"
assert_eq "drop equals-form --add-dir with a space in the path" "--allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir=/tmp/My Project --allow-all")"
assert_eq "drop equals-form variadic option with flattened values" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-tool=shell write --allow-all")"
assert_eq "equals-form value without spaces is kept" \
	"--add-dir=/tmp/project --allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir=/tmp/project --allow-all")"

# Argv is data: a quoted wildcard must not be expanded against the save hook's
# cwd and persisted as whatever files happen to live there.
assert_eq "wildcard option value is not glob-expanded" \
	"--allow-tool * --allow-all" \
	"$(cd "$SANDBOX/bin" && extract_cli_args copilot "copilot --allow-tool * --allow-all")"
assert_eq "variadic list detected from real --help spelling" \
	"--allow-tool --allow-url --available-tools --deny-tool --deny-url --excluded-tools --secret-env-vars" \
	"$(_copilot_variadic_flags)"

# `--deny-tool='shell(git push)'` reaches ps as `--deny-tool=shell(git push)`.
# Being variadic does not make that reconstructable: the `=` already delimited
# the value, and Copilot reads the fragment as a positional.
echo "== permission safety =="
# A restricting option whose value we cannot reproduce must not be guessed at:
# `--deny-tool 'shell(git push)'` and `--deny-tool a b` are identical after ps
# flattens them, and preserving the wrong one quietly widens what the agent may
# do. Dropping the denial alone would do the same, so every replay flag goes too
# and the restored session falls back to Copilot's prompting defaults.
assert_eq "ambiguous denial drops, taking the blanket allow with it" "" \
	"$(extract_cli_args copilot "copilot --deny-tool shell write --allow-all")"
assert_eq "equals-form denial likewise" "" \
	"$(extract_cli_args copilot "copilot --deny-tool=shell(git push) --allow-all")"
assert_eq "permission loss drops every replay flag" "" \
	"$(extract_cli_args copilot "copilot --deny-tool a b --yolo --allow-all-tools --autopilot")"
assert_eq "dropped denial also removes granular grants" "" \
	"$(extract_cli_args copilot "copilot --allow-tool=shell(git:*) --deny-tool=shell(git push) --allow-all")"
assert_eq "dash-prefixed value fragments are not replayed as options" "" \
	"$(extract_cli_args copilot "copilot --deny-tool=shell(git push --force) --allow-all")"
# Granting options keep the variadic exemption: mis-splitting one only ever
# narrows access, so there is no escalation to guard against.
assert_eq "granting variadic keeps its values and the blanket allow" \
	"--allow-tool shell write --allow-all" \
	"$(extract_cli_args copilot "copilot --allow-tool shell write --allow-all")"
assert_eq "a denial we can reproduce is preserved" \
	"--deny-tool shell --allow-all" \
	"$(extract_cli_args copilot "copilot --deny-tool shell --allow-all")"

# Linux/WSL never has to guess: /proc/<pid>/cmdline keeps argv boundaries that
# ps destroys, so a quoted value and a genuine list are distinguishable.
if [ -r "/proc/$$/cmdline" ]; then
	echo "== exact argv (/proc/<pid>/cmdline) =="
	# Mirror the real launcher shape: argv[0] is the interpreter and argv[1] is
	# a script path ending in /copilot, exactly as the npm loader appears.
	mkdir -p "$SANDBOX/launcher"
	printf '#!/usr/bin/env bash\nsleep 30\n' >"$SANDBOX/launcher/copilot"
	chmod +x "$SANDBOX/launcher/copilot"
	# stdout is redirected: the harness captures this suite in a command
	# substitution, which would otherwise wait on a background job holding the
	# pipe open.
	bash "$SANDBOX/launcher/copilot" --deny-tool "shell(git push)" --allow-all >/dev/null 2>&1 &
	QUOTED_PID=$!
	bash "$SANDBOX/launcher/copilot" --deny-tool a b --allow-all >/dev/null 2>&1 &
	LIST_PID=$!
	bash "$SANDBOX/launcher/copilot" "--deny-tool=shell(git push)" --allow-all >/dev/null 2>&1 &
	EQUALS_PID=$!
	sleep 1
	# ps flattens both to the same string; only cmdline tells them apart.
	assert_eq "quoted denial is recognised as one value and dropped" "" \
		"$(extract_cli_args copilot "copilot --deny-tool shell(git push) --allow-all" "$QUOTED_PID")"
	assert_eq "genuine denial list is preserved despite identical ps output" \
		"--deny-tool a b --allow-all" \
		"$(extract_cli_args copilot "copilot --deny-tool a b --allow-all" "$LIST_PID")"
	assert_eq "equals-form exact denial drop is reported as a permission loss" "" \
		"$(extract_cli_args copilot "copilot --deny-tool=shell(git push) --allow-all" "$EQUALS_PID")"
	kill "$QUOTED_PID" "$LIST_PID" "$EQUALS_PID" 2>/dev/null
else
	printf '  [skip] exact argv from /proc (not available on this platform)\n'
fi

echo "== prompt-only options =="
# Copilot refuses --attachment on an interactive resume, and the prompt
# truncation only reaches flags written after the prompt.
assert_eq "strip --attachment placed before the prompt" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --attachment /tmp/a.png -p summarize this")"
assert_eq "strip --attachment with no prompt at all" "--allow-all" \
	"$(extract_cli_args copilot "copilot --attachment /tmp/a.png --allow-all")"
assert_eq "strip equals-form --attachment" "--allow-all" \
	"$(extract_cli_args copilot "copilot --attachment=/tmp/a.png --allow-all")"

echo "== hidden launch-mode selectors =="
# --worktree/-w and --cloud never appear in --help, so discovery cannot learn
# them, yet Copilot refuses each one alongside --resume.
assert_eq "strip --worktree" "--allow-all" \
	"$(extract_cli_args copilot "copilot --worktree --allow-all")"
assert_eq "strip --worktree=<name>" "--allow-all" \
	"$(extract_cli_args copilot "copilot --worktree=feature-x --allow-all")"
assert_eq "strip short -w" "--allow-all" \
	"$(extract_cli_args copilot "copilot -w --allow-all")"
assert_eq "strip --cloud" "--experimental --allow-all" \
	"$(extract_cli_args copilot "copilot --experimental --cloud --allow-all")"

echo "== --help probe cost =="
# The save hook runs every few minutes: discovery must not exec the CLI once per
# pane. The caches live in shell vars, and extract_cli_args runs in a $()
# subshell, so they only pay off when warmed in the parent shell.
unset _TOOL_HELP_copilot _SESSION_FLAGS_copilot _COPILOT_VARIADIC_FLAGS
: >"$HELP_CALLS"
_warm_session_discovery "$(printf 'pane\tcopilot\t1\targs\n')"
for _ in 1 2 3 4 5 6 7 8; do
	extract_cli_args copilot "copilot --allow-all --deny-tool a" >/dev/null
done
assert_eq "one --help exec per save, not per pane" "1" \
	"$(wc -l <"$HELP_CALLS" | tr -d ' ')"

echo
echo "copilot unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
