#!/usr/bin/env bash
# Benchmark the save hook in an isolated tmux sandbox (inside Docker).
#
# Usage:
#   bench-save-hook.sh <repo_path> [runs] [panes] [assistants]
#
# Output is key=value lines:
#   repo=...
#   runs=... panes=... assistants=...
#   run_01=0.123
#   ...
#   avg=...
#   min=...
#   max=...
#   saved_sessions=...
set -euo pipefail

REPO_PATH="${1:?repo path required}"
RUNS="${2:-7}"
PANES="${3:-124}"
ASSISTANTS="${4:-60}"

if [ "$ASSISTANTS" -gt "$PANES" ]; then
	echo "assistants ($ASSISTANTS) cannot exceed panes ($PANES)" >&2
	exit 1
fi

BENCH_ROOT=$(mktemp -d)

# Isolation has to be in force before the EXIT trap below can fire, and before
# any tmux call. Two separate things defeat TMUX_TMPDIR, both silently and both
# exit 0:
#   - a directory that does not exist yet -- on every released tmux through
#     3.8 the unresolvable entry is dropped from the socket search list and
#     /tmp/tmux-$(id -u)/default is used instead, so a cleanup firing between
#     the trap and the mkdir killed the real server (master now errors here);
#   - an inherited $TMUX -- it is consulted before the search list, so running
#     this from inside tmux addresses the live server whatever TMUX_TMPDIR says.
# Every tmux call below also carries an explicit -S, so isolation never rests on
# environment reasoning alone.
unset TMUX
export HOME="$BENCH_ROOT/home"
export TMUX_TMPDIR="$BENCH_ROOT/tmux"
export TMUX_ASSISTANT_RESURRECT_DIR="$BENCH_ROOT/state"
mkdir -p "$HOME/.tmux/resurrect" "$TMUX_TMPDIR" "$TMUX_ASSISTANT_RESURRECT_DIR" "$BENCH_ROOT/bin"
# An explicit -S skips make_label(), which is what would normally create this
# directory, so create it here -- and at 0700, because make_label rejects a
# socket directory with looser permissions. The save hook under test uses bare
# tmux calls, which resolve to this same path through TMUX_TMPDIR.
mkdir -m 700 "$TMUX_TMPDIR/tmux-$(id -u)"
BENCH_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"

cleanup() {
	# `tmux kill-server` only signals the server: it and all $PANES pane shells are
	# still alive when the command returns, and each interactive shell flushes
	# ~/.bash_history into $HOME on its way out. Removing the tree during that window
	# loses a race -- rm walks $HOME, unlinks what it saw, then the final rmdir gets
	# ENOTEMPTY because a dying shell recreated .bash_history behind it:
	#
	#   rm: cannot remove '/tmp/tmp.XXXXXXXX/home': Directory not empty
	#
	# Under `set -e` that fails the EXIT trap, which turns an exit status of 0 into 1
	# and throws away a benchmark that had already printed its numbers. (A trap that
	# *succeeds* cannot mask a real failure the other way -- bash keeps the status
	# from before the trap ran -- so retrying here is safe.) The race is self-limiting:
	# once the last shell is reaped nothing recreates anything, so retry rather than
	# guess at how long teardown takes. Rare on a fast machine, routine on a 2-vCPU
	# CI runner with 116 shells exiting at once.
	# Explicit -S: a bare kill-server here is what makes this script unsafe
	# outside Docker. stderr is kept so a misroute is visible, not silent.
	if [ -S "$BENCH_SOCKET" ]; then
		tmux -S "$BENCH_SOCKET" -f /dev/null kill-server || true
	fi
	local i
	for i in $(seq 1 50); do
		rm -rf "$BENCH_ROOT" 2>/dev/null && return 0
		sleep 0.1
	done
	# Five seconds in, something other than teardown is holding the tree. Leave the
	# directory rather than the benchmark: this runs in a `docker run --rm` container
	# whose filesystem is discarded either way.
	rm -rf "$BENCH_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# Mock claude binary so we can create many assistant processes without network/API keys.
# Must answer `--help` immediately: the save hook probes `claude --help` to
# discover session-identity flags (extract_cli_args), so a mock that slept on
# every invocation would hang that probe — and with the save-hook watchdog armed,
# get the whole hook SIGKILLed at the deadline. Only the long-lived assistant
# invocation (`claude --resume ...`) should sleep.
cat >"$BENCH_ROOT/bin/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
*" --help "* | *" -h "*)
	printf '%s\n' 'Usage: claude [options]' '  -r, --resume <id>' '  --model <model>'
	exit 0
	;;
esac
sleep 600
SH
chmod +x "$BENCH_ROOT/bin/claude"
export PATH="$BENCH_ROOT/bin:$PATH"

# Build pane/process load.
# -f /dev/null on every call, not just the one that happens to start the
# server: a private socket does not make the server private. tmux still loads
# the system file and, because $XDG_CONFIG_HOME is inherited rather than
# sandboxed along with $HOME, $XDG_CONFIG_HOME/tmux/tmux.conf -- whose
# run-shell and plugin lines would then execute inside the benchmark. Whichever
# call finds no server starts one, so pinning all of them is the only form of
# the rule that cannot be defeated by adding a call above this loop.
for i in $(seq 1 "$PANES"); do
	tmux -S "$BENCH_SOCKET" -f /dev/null new-session -d -s "bench$i" -c /tmp
done
for i in $(seq 1 "$ASSISTANTS"); do
	tmux -S "$BENCH_SOCKET" -f /dev/null send-keys -t "bench$i:0.0" "claude --resume ses_$i" Enter
done
sleep 1

# Warmup run.
bash "$REPO_PATH/scripts/save-assistant-sessions.sh" >/dev/null 2>&1 || true

echo "repo=$REPO_PATH"
echo "runs=$RUNS panes=$PANES assistants=$ASSISTANTS"

TIMES_FILE="$BENCH_ROOT/times.txt"
: >"$TIMES_FILE"
for r in $(seq 1 "$RUNS"); do
	t=$( (TIMEFORMAT=%3R; time bash "$REPO_PATH/scripts/save-assistant-sessions.sh" >/dev/null 2>&1) 2>&1)
	echo "$t" >>"$TIMES_FILE"
	printf 'run_%02d=%s\n' "$r" "$t"
done

avg=$(awk '{s+=$1; n+=1} END { if (n>0) printf "%.3f", s/n; else print "0.000" }' "$TIMES_FILE")
min=$(sort -n "$TIMES_FILE" | head -n1)
max=$(sort -n "$TIMES_FILE" | tail -n1)
saved=$(jq '.sessions | length' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null || echo 0)

echo "avg=$avg"
echo "min=$min"
echo "max=$max"
echo "saved_sessions=$saved"
