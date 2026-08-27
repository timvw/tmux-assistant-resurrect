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
	tmux kill-server >/dev/null 2>&1 || true
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

export HOME="$BENCH_ROOT/home"
export TMUX_TMPDIR="$BENCH_ROOT/tmux"
export TMUX_ASSISTANT_RESURRECT_DIR="$BENCH_ROOT/state"
mkdir -p "$HOME/.tmux/resurrect" "$TMUX_TMPDIR" "$TMUX_ASSISTANT_RESURRECT_DIR" "$BENCH_ROOT/bin"

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
for i in $(seq 1 "$PANES"); do
	tmux new-session -d -s "bench$i" -c /tmp
done
for i in $(seq 1 "$ASSISTANTS"); do
	tmux send-keys -t "bench$i:0.0" "claude --resume ses_$i" Enter
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
