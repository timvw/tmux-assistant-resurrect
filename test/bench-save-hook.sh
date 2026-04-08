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
	tmux kill-server >/dev/null 2>&1 || true
	rm -rf "$BENCH_ROOT"
}
trap cleanup EXIT

export HOME="$BENCH_ROOT/home"
export TMUX_TMPDIR="$BENCH_ROOT/tmux"
export TMUX_ASSISTANT_RESURRECT_DIR="$BENCH_ROOT/state"
mkdir -p "$HOME/.tmux/resurrect" "$TMUX_TMPDIR" "$TMUX_ASSISTANT_RESURRECT_DIR" "$BENCH_ROOT/bin"

# Mock claude binary so we can create many assistant processes without network/API keys.
cat >"$BENCH_ROOT/bin/claude" <<'SH'
#!/usr/bin/env bash
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
	t=$((TIMEFORMAT=%3R; time bash "$REPO_PATH/scripts/save-assistant-sessions.sh" >/dev/null 2>&1) 2>&1)
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
