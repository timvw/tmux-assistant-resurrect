#!/usr/bin/env bash
# Run a benchmark matrix in Docker and write CSV + Markdown summary.
#
# Example:
#   test/bench-matrix.sh \
#     --head-repo "$PWD" \
#     --base-repo /tmp/base \
#     --runs 5 \
#     --output-csv test-results/benchmark.csv \
#     --output-md test-results/benchmark.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_SCRIPT="$SCRIPT_DIR/bench-save-hook.sh"

HEAD_REPO=""
BASE_REPO=""
RUNS=7
IMAGE="tmux-assistant-resurrect-test"
OUT_CSV="test-results/benchmark.csv"
OUT_MD="test-results/benchmark.md"

# Default scenarios: "<panes> <assistants>"
SCENARIOS=(
	"116 40"
	"124 60"
	"124 100"
	"200 100"
)

usage() {
	cat <<EOF
Usage: $(basename "$0") --head-repo <path> [options]

Options:
  --head-repo <path>   Repo to benchmark (required)
  --base-repo <path>   Optional baseline repo for side-by-side comparison
  --runs <n>           Timed runs per scenario (default: $RUNS)
  --image <name>       Docker image to run benchmark in (default: $IMAGE)
  --output-csv <path>  Output CSV path (default: $OUT_CSV)
  --output-md <path>   Output Markdown path (default: $OUT_MD)
  --help               Show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--head-repo)
		HEAD_REPO="$2"
		shift 2
		;;
	--base-repo)
		BASE_REPO="$2"
		shift 2
		;;
	--runs)
		RUNS="$2"
		shift 2
		;;
	--image)
		IMAGE="$2"
		shift 2
		;;
	--output-csv)
		OUT_CSV="$2"
		shift 2
		;;
	--output-md)
		OUT_MD="$2"
		shift 2
		;;
	--help)
		usage
		exit 0
		;;
	*)
		echo "Unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
done

if [ -z "$HEAD_REPO" ]; then
	echo "--head-repo is required" >&2
	usage
	exit 1
fi

mkdir -p "$(dirname "$OUT_CSV")" "$(dirname "$OUT_MD")"
echo "variant,commit,panes,assistants,runs,avg,min,max,saved_sessions" >"$OUT_CSV"

run_one() {
	local variant="$1"
	local repo="$2"
	local commit="$3"
	local panes="$4"
	local assistants="$5"

	local output
	output=$(docker run --rm --entrypoint bash \
		-v "$BENCH_SCRIPT:/bench.sh:ro" \
		-v "$repo:/repo:ro" \
		"$IMAGE" \
		/bench.sh /repo "$RUNS" "$panes" "$assistants")

	local avg min max saved
	avg=$(echo "$output" | awk -F= '/^avg=/{print $2}')
	min=$(echo "$output" | awk -F= '/^min=/{print $2}')
	max=$(echo "$output" | awk -F= '/^max=/{print $2}')
	saved=$(echo "$output" | awk -F= '/^saved_sessions=/{print $2}')

	echo "$variant,$commit,$panes,$assistants,$RUNS,$avg,$min,$max,$saved" >>"$OUT_CSV"
	echo "[$variant] panes=$panes assistants=$assistants avg=$avg min=$min max=$max saved=$saved" >&2
}

HEAD_COMMIT=$(cd "$HEAD_REPO" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BASE_COMMIT=""
if [ -n "$BASE_REPO" ]; then
	BASE_COMMIT=$(cd "$BASE_REPO" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

for s in "${SCENARIOS[@]}"; do
	panes="${s%% *}"
	assistants="${s##* }"
	if [ -n "$BASE_REPO" ]; then
		run_one "base" "$BASE_REPO" "$BASE_COMMIT" "$panes" "$assistants"
	fi
	run_one "head" "$HEAD_REPO" "$HEAD_COMMIT" "$panes" "$assistants"
done

{
	echo "## Benchmark Results"
	echo ""
	echo "- head: \`$HEAD_COMMIT\` (\`$HEAD_REPO\`)"
	if [ -n "$BASE_REPO" ]; then
		echo "- base: \`$BASE_COMMIT\` (\`$BASE_REPO\`)"
	fi
	echo "- runs per scenario: \`$RUNS\`"
	echo "- docker image: \`$IMAGE\`"
	echo ""
	if [ -n "$BASE_REPO" ]; then
		echo "| Panes | Sessions | Base avg (s) | Head avg (s) | Speedup | Reduction | Base saved | Head saved |"
		echo "|---:|---:|---:|---:|---:|---:|---:|---:|"
		for s in "${SCENARIOS[@]}"; do
			panes="${s%% *}"
			assistants="${s##* }"
			base_avg=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="base" && $3==p && $4==a {print $6}' "$OUT_CSV")
			head_avg=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $6}' "$OUT_CSV")
			base_saved=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="base" && $3==p && $4==a {print $9}' "$OUT_CSV")
			head_saved=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $9}' "$OUT_CSV")
			speedup=$(awk -v b="$base_avg" -v h="$head_avg" 'BEGIN { if (h==0) {print "inf"} else {printf "%.2fx", b/h} }')
			reduction=$(awk -v b="$base_avg" -v h="$head_avg" 'BEGIN { if (b==0) {print "0.0%"} else {printf "%.1f%%", (1-(h/b))*100} }')
			echo "| $panes | $assistants | $base_avg | $head_avg | $speedup | $reduction | $base_saved | $head_saved |"
		done
	else
		echo "| Panes | Sessions | Head avg (s) | Head min (s) | Head max (s) | Saved sessions |"
		echo "|---:|---:|---:|---:|---:|---:|"
		for s in "${SCENARIOS[@]}"; do
			panes="${s%% *}"
			assistants="${s##* }"
			head_avg=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $6}' "$OUT_CSV")
			head_min=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $7}' "$OUT_CSV")
			head_max=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $8}' "$OUT_CSV")
			head_saved=$(awk -F, -v p="$panes" -v a="$assistants" '$1=="head" && $3==p && $4==a {print $9}' "$OUT_CSV")
			echo "| $panes | $assistants | $head_avg | $head_min | $head_max | $head_saved |"
		done
	fi
	echo ""
	echo "Raw CSV: \`$OUT_CSV\`"
} >"$OUT_MD"

echo "Wrote $OUT_CSV"
echo "Wrote $OUT_MD"
