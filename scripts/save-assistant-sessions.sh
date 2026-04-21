#!/usr/bin/env bash
# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# Detection: inspects child processes of each tmux pane shell via ps.
# Session IDs: extracted from process args, hook state files, or tool-native files.
#
# Called automatically by tmux-resurrect after each save via:
#   set -g @resurrect-hook-post-save-all '/path/to/save-assistant-sessions.sh'

set -euo pipefail

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
RESURRECT_DIR="${HOME}/.tmux/resurrect"
OUTPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-save.log"

mkdir -p -m 0700 "$STATE_DIR"
mkdir -p "$RESURRECT_DIR"

# Rotate log: keep only the most recent 500 lines to prevent unbounded growth
# (continuum saves every 5 minutes, so this grows ~12 lines/hour).
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

USED_CODEX_SESSION_IDS=""

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

	# Method 2: --resume flag in process args (chicken-and-egg fallback)
	# After restore, claude is launched as `claude --resume <session_id>`.
	# Supports both `--resume <id>` and `--resume=<id>` forms.
	# If the SessionStart hook hasn't fired yet, the ID is still in the args.
	local sid
	sid=$(echo "$args" | sed -n "s/.*--resume[= ] *\([A-Za-z0-9_-]*\).*/\1/p")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
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
		sid=$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    cur = conn.cursor()
    cur.execute(
        'SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1',
        (sys.argv[2],))
    row = cur.fetchone()
    if row:
        print(row[0])
    conn.close()
except Exception:
    pass
" "$db_file" "$cwd" 2>/dev/null || true)
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
	# SQLite: ~/.codex/state_5.sqlite, table `threads`, columns id/cwd/
	# updated_at/archived).  This is the canonical current source — codex
	# writes a `threads` row per session and bumps `updated_at` on every
	# user turn.  A long-lived session that started on an earlier day
	# keeps its same `id` in this table even though no new rollout JSONL
	# is ever written, which is exactly the case Method 4 misses.
	#
	# Strategy: among threads matching our process's cwd that are unarchived
	# and have been updated during this process's lifetime, pick the most
	# recently updated one that isn't already assigned to another pane.
	#
	# The DB file is versioned (state_5.sqlite, bumping on schema changes).
	# Resolve to the newest `state_*.sqlite` so a future bump doesn't
	# silently disable this method.
	local state_db
	state_db=$(ls -t "${HOME}/.codex"/state_*.sqlite 2>/dev/null | head -1 || true)
	if [ -n "$cwd" ] && [ -n "$state_db" ] && [ -f "$state_db" ] && command -v python3 >/dev/null 2>&1; then
		local etimes
		etimes=$(ps -o etimes= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 - "$state_db" "$cwd" "$etimes" <<'PY'
import os, sqlite3, sys, time

state_db = sys.argv[1]
cwd = sys.argv[2]
etimes_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

process_start = None
if etimes_raw.isdigit():
    process_start = time.time() - int(etimes_raw)

# Open read-only so we never conflict with a running codex writer.
try:
    con = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
except sqlite3.Error:
    sys.exit(0)

try:
    cur = con.cursor()
    # updated_at is stored in seconds since epoch.
    cur.execute(
        "SELECT id, updated_at FROM threads "
        "WHERE cwd = ? AND archived = 0 "
        "ORDER BY updated_at DESC",
        (cwd,),
    )
    rows = cur.fetchall()
finally:
    con.close()

# Prefer threads whose last update happened after the process started
# (rules out stale threads in the same cwd). Fall back to most-recent
# overall if nothing qualifies — covers the edge case where a session
# was spawned but hasn't had any user turns yet.
def pick(rows, require_after_start):
    for sid, updated_at in rows:
        if sid in used:
            continue
        if require_after_start and process_start is not None and updated_at < process_start:
            continue
        return sid
    return None

sid = pick(rows, require_after_start=True) or pick(rows, require_after_start=False)
if sid:
    print(sid)
PY
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
		local etimes
		etimes=$(ps -o etimes= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 - "$sessions_root" "$cwd" "$etimes" <<'PY'
import datetime, json, os, sys, time

sessions_root = sys.argv[1]
cwd = sys.argv[2]
etimes_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

process_start = None
if etimes_raw.isdigit():
    process_start = time.time() - int(etimes_raw)

def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

candidates = []
for root, _, files in os.walk(sessions_root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                first = f.readline()
            if not first:
                continue
            record = json.loads(first)
            if record.get("type") != "session_meta":
                continue
            payload = record.get("payload") or {}
            if payload.get("cwd") != cwd:
                continue
            sid = payload.get("id")
            if not sid:
                continue
            candidates.append((sid, parse_ts(payload.get("timestamp")), os.path.getmtime(path)))
        except Exception:
            continue

if not candidates:
    sys.exit(0)

def score(item):
    sid, session_start, mtime = item
    reused = sid in used
    if process_start is None or session_start is None:
        prior = 0
        distance = float("inf")
    else:
        prior = 1 if session_start <= process_start + 120 else 0
        distance = abs(process_start - session_start)
    return (
        0 if reused else 1,
        prior,
        -distance,
        mtime,
    )

best = max(candidates, key=score)
print(best[0])
PY
		)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

register_codex_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_CODEX_SESSION_IDS" in
	*"$sid"*) ;;
	*)
		USED_CODEX_SESSION_IDS="${USED_CODEX_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

# --- CLI args extraction ---

# Extract CLI args from a process's full command line, stripping the binary
# name/path and tool-specific session/resume arguments.
#
# Usage: extract_cli_args <tool> <full_args_from_ps>
# Returns: the remaining flags/args as a single whitespace-normalized string.
#
# Per-tool stripping:
#   claude:   --resume <id>, --resume=<id>
#   opencode: -s <id>, --session <id>, --session=<id>
#   codex:    resume <id> (positional subcommand)
extract_cli_args() {
	local tool="$1" raw_args="$2"

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

	# Strip tool-specific session/resume args.
	# Patterns use [= ] *  to handle both --flag=val and --flag val forms,
	# and to tolerate multiple spaces between flag and value.
	case "$tool" in
	claude)
		# --resume <id> or --resume=<id>
		args=$(echo "$args" | sed -E 's/--resume[= ] *[^ ]*//')
		;;
	opencode)
		# -s <id>, --session <id>, --session=<id>
		args=$(echo "$args" | sed -E 's/--session[= ] *[^ ]*//; s/-s  *[^ ]*//')
		;;
	codex)
		# resume <id> (positional)
		args=$(echo "$args" | sed -E 's/resume  *[^ ]*//')
		;;
	esac

	# Normalize whitespace: collapse multiple spaces, trim leading/trailing
	echo "$args" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

# Resolve all detected assistant candidates for one pane and emit at most one
# session entry (first resolvable candidate in BFS order).
#
# Preserves legacy OpenCode behavior:
#   pass 1: PID-specific only (no DB fallback)
#   pass 2: OpenCode-only with DB fallback enabled
resolve_pane_candidates() {
	local pane_target="$1"
	local pane_cwd="$2"
	local pane_candidates="$3"
	local us="$4"
	local has_assoc_cache="$5"
	local state_cache_file="$6"
	local parts_file="$7"

	local resolved=0 first_tool="" first_pid=""
	for pass in 1 2; do
		[ "$resolved" -eq 1 ] && break
		local allow_opencode_db=0
		[ "$pass" -eq 2 ] && allow_opencode_db=1
		while IFS="$us" read -r cand_tool cand_pid cand_args; do
			[ -z "$cand_tool" ] && continue
			[ -z "$first_tool" ] && first_tool="$cand_tool" && first_pid="$cand_pid"

			# Pass 2 is only for OpenCode DB fallback.
			if [ "$pass" -eq 2 ] && [ "$cand_tool" != "opencode" ]; then
				continue
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

			local session_id=""
			case "$cand_tool" in
			claude)
				session_id="$cached_sid"
				# Keep legacy fallback behavior when cache misses (state file + --resume).
				[ -z "$session_id" ] && session_id=$(get_claude_session "$cand_pid" "$cand_args")
				;;
			opencode)
				session_id="$cached_sid"
				[ -z "$session_id" ] && session_id=$(get_opencode_session "$cand_pid" "$cand_args" "$pane_cwd" "$allow_opencode_db")
				;;
			codex) session_id=$(get_codex_session "$cand_pid" "$cand_args" "$pane_cwd") ;;
			esac

			if [ -n "$session_id" ]; then
				local cli_args model="" env_json="null" state_file=""
				cli_args=$(extract_cli_args "$cand_tool" "$cand_args")
				model="$cached_model"
				env_json="$cached_env"

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

				# Fallback: parse --model from CLI args if not in state file.
				# Regex stored in variable for bash 3.2 compat (inline capture groups fail).
				local _model_re='--model[= ]([^ ]+)'
				if [ -z "$model" ] && [[ "$cand_args" =~ $_model_re ]]; then
					model="${BASH_REMATCH[1]}"
				fi

				# Write TSV for batch JSON conversion (replaces per-entry jq -n).
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$pane_target" "$cand_tool" "$session_id" "$pane_cwd" "$cand_pid" "$model" "$cli_args" "$env_json" >>"$parts_file"

				[ "$cand_tool" = "codex" ] && register_codex_session_id "$session_id"
				resolved=1
				break
			fi
		done <<<"$pane_candidates"
	done

	if [ "$resolved" -eq 0 ] && [ -n "$first_tool" ]; then
		log "detected $first_tool in $pane_target (pid $first_pid) but no session ID available"
	fi
}

# --- Main ---

main() {
	PS_FILE=$(mktemp)
	PANE_FILE=$(mktemp)
	PARTS_FILE=$(mktemp)
	STATE_CACHE_FILE=$(mktemp)
	trap 'rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE" "$STATE_CACHE_FILE"' EXIT INT TERM

	# Timestamp for the JSON output envelope
	local SAVE_TS
	SAVE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Snapshot process table and pane info to temp files (each read once)
	ps -eo pid=,ppid=,args= >"$PS_FILE" 2>/dev/null
	if [ ! -s "$PS_FILE" ]; then
		log "ps snapshot failed or empty, skipping save"
		rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE"
		return 1
	fi
	tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}" >"$PANE_FILE"

	# --- Single awk pass: detect assistant tools across ALL pane process trees ---
	# Replaces ~200 separate echo|awk pipe invocations with one pass.
	# Reads pane list + ps snapshot, builds process tree in memory,
	# BFS-walks descendants for each pane PID, detects tools.
	# Output (tab-delimited): target\ttool\ttool_pid\ttool_args\tcwd
	# NOTE: emit all candidates per pane (pane PID + descendants) in BFS order.
	# The shell pass below preserves legacy two-pass OpenCode behavior:
	# 1) PID-specific only, then 2) DB fallback.
	local MATCHES
	MATCHES=$(awk '
		NR == FNR {
			# First file: pane data (pipe-delimited)
			split($0, p, "|")
			pane_target[p[2]] = p[1]
			pane_cwd[p[2]] = p[3]
			pane_list[++pane_count] = p[2]
			next
		}
		{
			# Second file: ps output (whitespace-delimited)
			pid = $1+0; ppid = $2+0
			line = $0
			sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
			gsub(/\n/, " ", line)  # Normalize multi-line args (Linux prctl)

			proc_args[pid] = line
			# First child concatenation produces "" SUBSEP pid; the k > 0 guard
			# in the BFS loop below filters the resulting empty first element.
			child_list[ppid] = (ppid in child_list) ? child_list[ppid] SUBSEP pid : "" pid

			# Detect tool in command args
			# Keep patterns aligned with detect_tool() in lib-detect.sh:
			# - bare binary at start, or path component (/tool)
			# - opencode excludes "opencode run " subprocesses
			if      (line ~ /(^claude( |$)|\/claude( |$))/)                                      proc_tool[pid] = "claude"
			else if (line ~ /(^opencode( |$)|\/opencode( |$))/ && line !~ /opencode run /)       proc_tool[pid] = "opencode"
			else if (line ~ /(^codex( |$)|\/codex( |$))/)                                        proc_tool[pid] = "codex"
		}
		END {
			for (i = 1; i <= pane_count; i++) {
				root = pane_list[i]+0
				target = pane_target[pane_list[i]]
				cwd = pane_cwd[pane_list[i]]

				# Check pane PID itself (handles exec-replaced shells)
				if (root in proc_tool && proc_tool[root] != "") {
					printf "%s\t%s\t%d\t%s\t%s\n", target, proc_tool[root], root, proc_args[root], cwd
				}

				# BFS through descendant processes
				delete queue
				qs = 1; qe = 0
				if (root in child_list) {
					nc = split(child_list[root], kids, SUBSEP)
					for (j = 1; j <= nc; j++) {
						k = kids[j]+0
						if (k > 0) { queue[++qe] = k }
					}
				}

				while (qs <= qe) {
					cur = queue[qs++]+0
					if (cur in proc_tool && proc_tool[cur] != "") {
						printf "%s\t%s\t%d\t%s\t%s\n", target, proc_tool[cur], cur, proc_args[cur], cwd
					}
					if (cur in child_list) {
						nc = split(child_list[cur], kids, SUBSEP)
						for (j = 1; j <= nc; j++) {
							k = kids[j]+0
							if (k > 0) { queue[++qe] = k }
						}
					}
				}
			}
		}
	' "$PANE_FILE" "$PS_FILE")

	rm -f "$PS_FILE" "$PANE_FILE"

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

	# Process only matched panes (those with a detected tool)
	if [ -n "$MATCHES" ]; then
		local current_target="" current_cwd="" pane_candidates=""
		while IFS=$'\t' read -r target tool cpid cargs cwd; do
			[ -z "$target" ] && continue

			# If pane changed, process the previous pane's candidate list.
			if [ -n "$current_target" ] && [ "$target" != "$current_target" ]; then
				resolve_pane_candidates "$current_target" "$current_cwd" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE"
				pane_candidates=""
			fi

			current_target="$target"
			current_cwd="$cwd"
			# Candidate tuples are US-delimited; a literal \x1f inside process args
			# would break parsing, but this is practically unlikely for CLI argv.
			pane_candidates="${pane_candidates}${tool}${US}${cpid}${US}${cargs}"$'\n'
		done <<<"$MATCHES"

		# Process final pane candidate list.
		if [ -n "$current_target" ] && [ -n "$pane_candidates" ]; then
			resolve_pane_candidates "$current_target" "$current_cwd" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE"
		fi
	fi

	# Single jq: convert TSV to JSON array + build final output (replaces N+3 jq calls)
	local count=0
	if [ -s "$PARTS_FILE" ]; then
		jq -Rs --arg ts "$SAVE_TS" '
			split("\n") | map(select(length > 0) | split("\t") |
			{pane:.[0], tool:.[1], session_id:.[2], cwd:.[3], pid:.[4], model:.[5], cli_args:.[6],
			 env:(.[7] // "null" | try fromjson catch null)})
			| {timestamp: $ts, sessions: .}
		' "$PARTS_FILE" >"$OUTPUT_FILE"
		count=$(jq '.sessions | length' "$OUTPUT_FILE")
	else
		jq -n --arg ts "$SAVE_TS" '{timestamp: $ts, sessions: []}' >"$OUTPUT_FILE"
	fi

	log "saved $count assistant session(s) to $OUTPUT_FILE"

	# Strip captured pane contents for assistant panes so tmux-resurrect
	# won't restore stale TUI output that the post-restore hook would
	# immediately replace. Non-assistant pane contents are preserved.
	if [ "$count" -gt 0 ]; then
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

	# Collect pane targets from the sessions we just saved
	local panes
	panes=$(jq -r '.sessions[].pane' "$OUTPUT_FILE" 2>/dev/null) || return 0
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
	done <<<"$panes"

	if [ "$removed" -gt 0 ]; then
		if tar cf - -C "$tmpdir" ./pane_contents/ | gzip >"${archive}.tmp" 2>/dev/null; then
			mv "${archive}.tmp" "$archive"
			log "stripped pane contents for $removed assistant pane(s)"
		else
			log "warning: failed to repack pane_contents archive"
			rm -f "${archive}.tmp"
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
	local session_id=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$cpid" "$cargs") ;;
	opencode) session_id=$(get_opencode_session "$cpid" "$cargs" "$cwd" "$allow_opencode_db") ;;
	codex) session_id=$(get_codex_session "$cpid" "$cargs" "$cwd") ;;
	esac

	if [ -n "$session_id" ]; then
		# Extract CLI args (flags without binary name and session/resume args)
		local cli_args
		cli_args=$(extract_cli_args "$tool" "$cargs")

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

		# Fallback: parse --model from CLI args if not in state file
		if [ -z "$model" ]; then
			model=$(echo "$cargs" | sed -n 's/.*--model[= ] *\([^ ]*\).*/\1/p')
		fi

		jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg pid "$cpid" \
			--arg model "$model" \
			--arg cli_args "$cli_args" \
			--argjson env "${env_json:-null}" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid, model: $model, cli_args: $cli_args, env: $env}' >>"$PARTS_FILE"
		if [ "$tool" = "codex" ]; then
			register_codex_session_id "$session_id"
		fi
		return 0
	else
		if [ "$log_missing" = "1" ]; then
			log "detected $tool in $target (pid $cpid) but no session ID available"
		fi
		return 1
	fi
}

# Allow sourcing this script without executing main (for unit tests).
# When sourced, only functions and variables are defined.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
