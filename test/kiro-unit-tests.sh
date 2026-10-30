#!/usr/bin/env bash
# Hermetic unit tests for Kiro CLI session detection / extraction / restore.
#
# Needs no kiro-cli binary and no tmux: sources the library functions directly
# and drives them against a fixture $KIRO_HOME/sessions/cli plus a fake
# `pid ppid` table (KIRO_PS_TABLE). Run with: bash test/kiro-unit-tests.sh
# (or: just test-kiro)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export KIRO_HOME="$SANDBOX/.kiro"
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
SESS="$KIRO_HOME/sessions/cli"
mkdir -p "$SESS" "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR"

# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"
# shellcheck source=../scripts/save-assistant-sessions.sh
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1
# shellcheck source=lib-assert.sh
source "$REPO_DIR/test/lib-assert.sh"

# PIDs are fake, so process start times are unknown and the stale-lock check
# is advisory (reports "not stale"). The recycled-PID case is covered below by
# overriding get_process_start_epoch.
SID_A="aaaaaaaa-1111-4111-8111-000000000001"
SID_B="bbbbbbbb-2222-4222-8222-000000000002"
SID_DEAD="dddddddd-4444-4444-8444-000000000004"
SID_OLD="cccccccc-3333-4333-8333-000000000003"
SID_NEW="eeeeeeee-5555-4555-8555-000000000005"
SID_NOJSON="ffffffff-6666-4666-8666-000000000006"

mk_session() { # sid pid started_at [nojson]
	printf '{"pid":%s,"started_at":"%s"}' "$2" "$3" >"$SESS/$1.lock"
	[ -n "${4:-}" ] || printf '{"session_id":"%s","cwd":"/work"}\n' "$1" >"$SESS/$1.json"
}

# Pane A: kiro-cli(100) -> chat(101) -> bun(102) -> acp(103)
# Pane B: kiro-cli(200) -> chat(201) -> bun(202) -> acp(203), same cwd as A
# Pane C: kiro-cli(300) -> ... -> acp(303), switched sessions in-TUI (2 locks)
# Pane D: kiro-cli(400) -> ... -> acp(403), lock but no session json
mk_session "$SID_A" 103 "2026-10-30T10:00:00.000Z"
mk_session "$SID_B" 203 "2026-10-30T10:05:00.000Z"
mk_session "$SID_DEAD" 999 "2026-10-01T10:00:00.000Z"
mk_session "$SID_OLD" 303 "2026-10-30T09:00:00.000Z"
mk_session "$SID_NEW" 303 "2026-10-30T11:00:00.000Z"
mk_session "$SID_NOJSON" 403 "2026-10-30T11:00:00.000Z" nojson
export KIRO_PS_TABLE="1 0
100 1
101 100
102 101
103 102
200 1
201 200
202 201
203 202
300 1
301 300
302 301
303 302
400 1
401 400
402 401
403 402"

echo "== detect_tool =="
assert_eq "bare kiro-cli"              "kiro" "$(detect_tool 'kiro-cli')"
assert_eq "kiro-cli chat"              "kiro" "$(detect_tool 'kiro-cli chat')"
assert_eq "kiro-cli chat --resume-id"  "kiro" "$(detect_tool "kiro-cli chat --resume-id $SID_A")"
assert_eq "kiro-cli with abs path"     "kiro" "$(detect_tool '/home/u/.local/bin/kiro-cli --agent dev')"
assert_eq "kiro-cli login is not chat" ""     "$(detect_tool 'kiro-cli login')"
assert_eq "kiro-cli settings ignored"  ""     "$(detect_tool 'kiro-cli settings list')"
assert_eq "kiro-cli-chat child ignored" ""    "$(detect_tool '/home/u/.local/bin/kiro-cli-chat chat')"
assert_eq "kiro-cli-chat acp ignored"  ""     "$(detect_tool '/home/u/.local/bin/kiro-cli-chat acp')"
assert_eq "bun tui.js ignored"         ""     "$(detect_tool '/home/u/.local/share/kiro-cli/bun /home/u/.local/share/kiro-cli/tui.js chat')"
assert_eq "kiro IDE launcher ignored"  ""     "$(detect_tool 'kiro .')"

echo "== awk detect_tool (same rules) =="
awk_detect() { printf '%s\n' "$1" | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk"; }
assert_eq "awk bare kiro-cli"      "kiro" "$(awk_detect 'kiro-cli')"
assert_eq "awk kiro-cli chat"      "kiro" "$(awk_detect 'kiro-cli chat --resume-id x')"
assert_eq "awk kiro-cli --flag"    "kiro" "$(awk_detect '/x/kiro-cli --v3')"
assert_eq "awk kiro-cli login"     ""     "$(awk_detect 'kiro-cli login')"
assert_eq "awk kiro-cli-chat acp"  ""     "$(awk_detect '/x/kiro-cli-chat acp')"

echo "== get_kiro_session: lock owned by the pane's process tree =="
assert_eq "pane A -> session A"                "$SID_A" "$(get_kiro_session 100 'kiro-cli')"
assert_eq "pane B same cwd -> session B"       "$SID_B" "$(get_kiro_session 200 'kiro-cli chat')"
assert_eq "in-TUI switch -> newest started_at" "$SID_NEW" "$(get_kiro_session 300 'kiro-cli')"
assert_eq "lock without json -> nothing"       ""       "$(get_kiro_session 400 'kiro-cli')"
assert_eq "unrelated pid -> nothing"           ""       "$(get_kiro_session 500 'kiro-cli')"

echo "== get_kiro_session: --resume-id fallback =="
assert_eq "argv --resume-id with json"     "$SID_DEAD" "$(get_kiro_session 500 "kiro-cli chat --resume-id $SID_DEAD")"
assert_eq "argv --resume-id= with json"    "$SID_DEAD" "$(get_kiro_session 500 "kiro-cli chat --resume-id=$SID_DEAD")"
assert_eq "argv --resume-id without json"  ""          "$(get_kiro_session 500 "kiro-cli chat --resume-id $SID_NOJSON")"
assert_eq "lock wins over argv"            "$SID_A"    "$(get_kiro_session 100 "kiro-cli chat --resume-id $SID_DEAD")"

echo "== stale lock from a recycled PID is ignored =="
touch -d '2026-01-01 00:00:00' "$SESS/$SID_A.lock"
assert_eq "lock older than the acp process" "" \
	"$(get_process_start_epoch() { date +%s; }; get_kiro_session 100 'kiro-cli')"
touch "$SESS/$SID_A.lock"

echo "== kiro_sessions_dir: KIRO_HOME from the process wins =="
PROC="$SANDBOX/proc"
ALT="$SANDBOX/alt-kiro"
mkdir -p "$PROC/600" "$PROC/601"
printf 'KIRO_HOME=%s\0' "$ALT" >"$PROC/600/environ"
printf 'PATH=/usr/bin\0' >"$PROC/601/environ"
assert_eq "process KIRO_HOME outranks the hook's" "$ALT/sessions/cli" \
	"$(ASSISTANT_PROC_ROOT="$PROC" kiro_sessions_dir 600)"
assert_eq "no process value -> hook's KIRO_HOME" "$SESS" \
	"$(ASSISTANT_PROC_ROOT="$PROC" kiro_sessions_dir 601)"

echo "== extract_cli_args: always empty for kiro (no help probe) =="
assert_eq "flags dropped" "" "$(extract_cli_args kiro "kiro-cli chat --agent dev --resume-id $SID_A 'hello'")"
assert_eq "_tool_help never runs a kiro binary" "" "$(PATH="$SANDBOX/nobin" _tool_help kiro)"

echo
echo "kiro unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
