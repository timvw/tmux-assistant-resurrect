#!/usr/bin/env bash
# Hermetic unit tests for saved-pane target resolution (issue #66).
#
# These need no tmux server: split_pane_target() is pure string work and
# match_pane_id() reads a `tmux list-panes -F` table on stdin, so the table is
# fabricated here. That is the point — the interesting session names contain
# ':' and '.', which tmux 3.4-3.6 silently rewrite to '_'. A test that asked a
# real tmux 3.4 (the Docker suite's version) for a session named "v1.2" would
# get "v1_2" and pass vacuously. Driving the functions directly covers the
# behaviour on every tmux version, including the ones CI cannot install.
#
# Run locally with:  bash test/target-resolution-unit-tests.sh  (or: just test-targets)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"

PASS=0
FAIL=0
assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
	fi
}

# Call split_pane_target and render the outcome as "session|window|index", or
# "<rejected>" when it returns non-zero. The variables are cleared first so a
# rejected target cannot report the previous call's values.
split() {
	PANE_TARGET_SESSION="" PANE_TARGET_WINDOW="" PANE_TARGET_INDEX=""
	if split_pane_target "$1"; then
		printf '%s|%s|%s' "$PANE_TARGET_SESSION" "$PANE_TARGET_WINDOW" "$PANE_TARGET_INDEX"
	else
		printf '<rejected>'
	fi
}

echo "== split_pane_target: ordinary targets =="
assert_eq "plain name" "work|0|0" "$(split 'work:0.0')"
assert_eq "multi-digit window/pane" "work|12|3" "$(split 'work:12.3')"
assert_eq "name with spaces" "my work|1|2" "$(split 'my work:1.2')"

echo "== split_pane_target: names holding the grammar's own separators =="
# Left-splitting these is what issue #66 reports: "${t%%:*}" makes "v1.2:0.0"
# into "v1" and "https://h/x:0.0" into "https". Splitting from the right is
# exact, because window and pane are always indices.
assert_eq "dot in name" "v1.2|0|0" "$(split 'v1.2:0.0')"
assert_eq "colon in name" "a:b|0|0" "$(split 'a:b:0.0')"
assert_eq "colon and dot" "a:b.c|1|2" "$(split 'a:b.c:1.2')"
assert_eq "url-like name" "https://github.com/x|0|0" "$(split 'https://github.com/x:0.0')"
assert_eq "name is itself a target" "x:0.0|0|0" "$(split 'x:0.0:0.0')"
assert_eq "pipe in name" "has|pipe|0|0" "$(split 'has|pipe:0.0')"
assert_eq "backslash in name" "back\\slash|0|0" "$(split 'back\slash:0.0')"
assert_eq "trailing dot in name" "dot.|0|0" "$(split 'dot.:0.0')"

echo "== split_pane_target: malformed targets are rejected =="
assert_eq "no separators" "<rejected>" "$(split 'work')"
assert_eq "colon but no dot" "<rejected>" "$(split 'work:0')"
assert_eq "dot but no colon" "<rejected>" "$(split 'work.0')"
assert_eq "dot before colon only" "<rejected>" "$(split 'v1.2:0')"
assert_eq "empty target" "<rejected>" "$(split '')"

# A pane table shaped exactly like resolve_tmux_pane_id() feeds in:
#   #{pane_id}|#{window_index}|#{pane_index}|#{session_name}
# Session name last, since it is the only field that may contain the delimiter.
PANES='%0|0|0|plain
%1|0|0|v1.2
%2|0|0|a:b
%3|0|0|has|pipe
%4|1|2|work
%5|0|0|work
%6|0|0|back\slash
%7|0|0|plainer'

match() { printf '%s\n' "$PANES" | match_pane_id "$1" "$2" "$3"; }

echo "== match_pane_id: exact field matching =="
assert_eq "plain session" "%0" "$(match 'plain' 0 0)"
assert_eq "dot in name" "%1" "$(match 'v1.2' 0 0)"
assert_eq "colon in name" "%2" "$(match 'a:b' 0 0)"
assert_eq "pipe in name (delimiter in the value)" "%3" "$(match 'has|pipe' 0 0)"
assert_eq "backslash in name" "%6" "$(match 'back\slash' 0 0)"
assert_eq "window and pane index both honoured" "%4" "$(match 'work' 1 2)"
assert_eq "same session, different window" "%5" "$(match 'work' 0 0)"

echo "== match_pane_id: no partial or prefix matches =="
# tmux itself prefix-matches session names, which is how a saved "https" target
# silently resolves against a different session. Matching literally must not.
assert_eq "prefix of a real name" "" "$(match 'plai' 0 0)"
assert_eq "real name is a prefix of another" "%0" "$(match 'plain' 0 0)"
assert_eq "longer name not matched by prefix" "%7" "$(match 'plainer' 0 0)"
assert_eq "left-split remnant of a dotted name" "" "$(match 'v1' 0 0)"
assert_eq "left-split remnant of a colon name" "" "$(match 'a' 0 0)"
assert_eq "left-split remnant of a piped name" "" "$(match 'has' 0 0)"
assert_eq "unknown session" "" "$(match 'nope' 0 0)"
assert_eq "known session, wrong window" "" "$(match 'plain' 9 0)"
assert_eq "known session, wrong pane" "" "$(match 'plain' 0 9)"
assert_eq "empty session name" "" "$(match '' 0 0)"

echo "== match_pane_id: malformed input is skipped, not fatal =="
assert_eq "empty table" "" "$(printf '' | match_pane_id 'plain' 0 0)"
assert_eq "row with too few fields" "" "$(printf '%%0|0|plain\n' | match_pane_id 'plain' 0 0)"
assert_eq "blank line ignored, good row still found" "%0" \
	"$(printf '\n%%0|0|0|plain\n' | match_pane_id 'plain' 0 0)"
assert_eq "malformed row before a good one" "%0" \
	"$(printf 'garbage\n%%0|0|0|plain\n' | match_pane_id 'plain' 0 0)"

echo "== match_pane_id: one id per match =="
# Two rows cannot legitimately share session/window/pane, but if the table were
# ever ambiguous the caller must still receive a single usable target rather
# than a multi-line string that would be pasted into a tmux -t argument.
assert_eq "duplicate rows yield the first id only" "%0" \
	"$(printf '%%0|0|0|plain\n%%9|0|0|plain\n' | match_pane_id 'plain' 0 0)"

echo "== round trip: split_pane_target output feeds match_pane_id =="
# This is the legacy-sidecar path in restore-assistant-sessions.sh: a JSON entry
# written before session_name/window_index/pane_index existed carries only the
# composed "pane" string, so it has to be taken apart before it can be matched.
round_trip() {
	PANE_TARGET_SESSION="" PANE_TARGET_WINDOW="" PANE_TARGET_INDEX=""
	split_pane_target "$1" || return 1
	printf '%s\n' "$PANES" | match_pane_id "$PANE_TARGET_SESSION" "$PANE_TARGET_WINDOW" "$PANE_TARGET_INDEX"
}

assert_eq "plain:0.0 -> pane id" "%0" "$(round_trip 'plain:0.0')"
assert_eq "v1.2:0.0 -> pane id" "%1" "$(round_trip 'v1.2:0.0')"
assert_eq "a:b:0.0 -> pane id" "%2" "$(round_trip 'a:b:0.0')"
assert_eq "has|pipe:0.0 -> pane id" "%3" "$(round_trip 'has|pipe:0.0')"
assert_eq "work:1.2 -> pane id" "%4" "$(round_trip 'work:1.2')"
assert_eq "back\\slash:0.0 -> pane id" "%6" "$(round_trip 'back\slash:0.0')"

echo "== save side: the three pane records join on pane id, free-form field last =="
# Static guards pin the tmux producer's side of the contract: the join key
# and field order in the `-F` strings save-assistant-sessions.sh hands to
# `list-panes`. The fixtures below exercise the standalone awk consumer
# directly, so these guards only need to cover the join key (#{pane_id}, not
# the recyclable #{pane_pid}) and each record's trailing free-form field.
SAVE_SH="$REPO_DIR/scripts/save-assistant-sessions.sh"
pane_formats=$(grep -o 'list-panes -a -F "[^"]*"' "$SAVE_SH" | sed 's/.*-F "//; s/"$//')
p_format=$(printf '%s\n' "$pane_formats" | grep '^P|' || true)
c_format=$(printf '%s\n' "$pane_formats" | grep '^C|' || true)
g_format=$(printf '%s\n' "$pane_formats" | grep '^G|' || true)

starts_with() {
	case "$2" in "$1"*) echo yes ;; *) echo no ;; esac
}
contains() {
	case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac
}

assert_eq "P record: tag, then pane id as the join key" "yes" "$(starts_with 'P|#{pane_id}|' "$p_format")"
assert_eq "C record: tag, then the same join key" "yes" "$(starts_with 'C|#{pane_id}|' "$c_format")"
assert_eq "G record: tag, then the same join key" "yes" "$(starts_with 'G|#{pane_id}|' "$g_format")"
assert_eq "P record ends with the session name" "#{session_name}" "${p_format##*|}"
assert_eq "C record ends with the pane path" "#{pane_current_path}" "${c_format##*|}"
assert_eq "G record ends with the session group" "#{session_group}" "${g_format##*|}"
assert_eq "P record still carries the pid, as data" "yes" "$(contains '|#{pane_pid}|' "$p_format")"

echo
echo "== save side: group-preferred session names =="
# save-assistant-sessions.awk joins the P/C/G records above and picks the
# session name to save. Driven here with two fabricated input files -- a
# pane table and a ps snapshot -- the same shape list-panes/ps would produce,
# rather than through a live tmux server.
SAVE_AWK="$REPO_DIR/scripts/save-assistant-sessions.awk"
LIB_AWK="$REPO_DIR/scripts/lib-detect.awk"
PANE_TMP=$(mktemp)
PS_TMP=$(mktemp)
trap 'rm -f "$PANE_TMP" "$PS_TMP"' EXIT

# One ps snapshot, shared by every case below: pid 100's pane runs "claude"
# directly, pid 300's pane runs a plain shell with no assistant.
printf '100 1 claude --resume ses_x\n300 1 -bash\n' >"$PS_TMP"

run_save_awk() {
	printf '%s\n' "$1" >"$PANE_TMP"
	awk -f "$LIB_AWK" -f "$SAVE_AWK" "$PANE_TMP" "$PS_TMP"
}

echo "-- grouped clone visible, base session still live: group name wins over the last-listed member --"
GROUPED_LIVE='P|%0|100|0|0|/dev/pts/1|main
P|%0|100|0|0|/dev/pts/1|main-0
C|%0|/home/user
G|%0|main'
out=$(run_save_awk "$GROUPED_LIVE")
assert_eq "one candidate row for the shared pane" "1" "$(printf '%s\n' "$out" | grep -c .)"
assert_eq "full row: base session name, not the last-listed clone" \
	"$(printf 'main:0.0\tclaude\t100\tclaude --resume ses_x\t/home/user\t/dev/pts/1\tmain\t0\t0')" "$out"

echo "-- non-grouped session, pane listed once: unchanged target and session, empty G record included --"
UNGROUPED='P|%1|100|0|0|/dev/pts/2|solo
C|%1|/home/user
G|%1|'
out=$(run_save_awk "$UNGROUPED")
assert_eq "full row: ungrouped pane, listed once, is unchanged" \
	"$(printf 'solo:0.0\tclaude\t100\tclaude --resume ses_x\t/home/user\t/dev/pts/2\tsolo\t0\t0')" "$out"

echo "-- link-window into a second ungrouped session: one row, last-listed name --"
LINKED_WINDOW='P|%4|100|0|0|/dev/pts/6|first
P|%4|100|0|0|/dev/pts/6|second
C|%4|/home/user
G|%4|'
out=$(run_save_awk "$LINKED_WINDOW")
assert_eq "linked-window pane yields exactly one row" "1" "$(printf '%s\n' "$out" | grep -c .)"
assert_eq "linked-window row uses the last-listed session name" \
	"$(printf 'second:0.0\tclaude\t100\tclaude --resume ses_x\t/home/user\t/dev/pts/6\tsecond\t0\t0')" "$out"

echo "-- three group members for one pane: still one row --"
THREE_MEMBERS='P|%2|100|0|0|/dev/pts/3|main
P|%2|100|0|0|/dev/pts/3|main-0
P|%2|100|0|0|/dev/pts/3|main-1
C|%2|/home/user
G|%2|main'
out=$(run_save_awk "$THREE_MEMBERS")
assert_eq "three group-member P rows still yield exactly one record" "1" "$(printf '%s\n' "$out" | grep -c .)"

echo "-- reused group name must not select a different pane --"
# The group name "main" is set once and stays attached to every remaining
# member even after the base session is renamed away. A second, unrelated
# session can later be named "main" too. Pane %0 (listed only as "main-0"
# and "renamed") must not be addressed as main:0.0, which belongs to the
# unrelated pane %2.
REUSED_NAME='P|%2|300|0|0|/dev/pts/5|main
P|%0|100|0|0|/dev/pts/1|main-0
P|%0|100|0|0|/dev/pts/1|renamed
C|%2|/home/user
C|%0|/home/user
G|%0|main'
out=$(run_save_awk "$REUSED_NAME")
assert_eq "one candidate row (pid 300 has no assistant)" \
	"1" "$(printf '%s\n' "$out" | grep -c .)"
target=$(printf '%s\n' "$out" | cut -f1)
case "$target" in
main-0:0.0 | renamed:0.0) reused_name_ok=yes ;;
*) reused_name_ok=no ;;
esac
assert_eq "resolves to a name %0 was actually listed under" "yes" "$reused_name_ok"
assert_eq "not the unrelated pane's main:0.0" "no" "$( [ "$target" = "main:0.0" ] && echo yes || echo no )"

echo "-- membership row supplies the indices, not whichever P row is last --"
# Pane %0 is linked into the unrelated "main" session at window 5, while its
# own group-member rows ("main-0", "main-1", "renamed") sit at window 0. The
# name check passes for "main", so the address must come from window 5 --
# pulling window/index from a different membership would address main:0.0,
# the unrelated pane %3.
LINKED_AT_DIFFERENT_INDEX='P|%3|300|0|0|/dev/pts/5|main
P|%0|100|5|0|/dev/pts/1|main
P|%0|100|0|0|/dev/pts/1|main-0
P|%0|100|0|0|/dev/pts/1|main-1
P|%0|100|0|0|/dev/pts/1|renamed
C|%3|/home/user
C|%0|/home/user
G|%3|
G|%0|main'
out=$(run_save_awk "$LINKED_AT_DIFFERENT_INDEX")
assert_eq "one candidate row (pid 300 has no assistant)" \
	"1" "$(printf '%s\n' "$out" | grep -c .)"
target=$(printf '%s\n' "$out" | cut -f1)
assert_eq "address comes from the row that matched the name" "main:5.0" "$target"

# Round-trip through the real restore-side matcher, built from the same P
# rows: main:5.0 must resolve to %0, and main:0.0 must resolve to %3.
LINKED_RESTORE_TABLE='%3|0|0|main
%0|5|0|main
%0|0|0|main-0
%0|0|0|main-1
%0|0|0|renamed'
assert_eq "main:5.0 resolves to the tracked pane" "%0" \
	"$(printf '%s\n' "$LINKED_RESTORE_TABLE" | match_pane_id "main" "5" "0")"
assert_eq "main:0.0 resolves to the unrelated pane, not the tracked one" "%3" \
	"$(printf '%s\n' "$LINKED_RESTORE_TABLE" | match_pane_id "main" "0" "0")"

echo "-- an ungrouped membership listed after the group ones must not blank the group name --"
# Pane %1 is in group "main" (via "main" and "main-0") and is also linked
# into ungrouped "zzz" at window 5. tmux lists the G record for each
# membership, so an ungrouped one reported last is empty; that empty value
# must not overwrite the group name recorded earlier for the same pane.
MIXED_MEMBERSHIP='P|%1|100|0|0|/dev/pts/1|main
P|%1|100|0|0|/dev/pts/1|main-0
P|%3|300|0|0|/dev/pts/2|scratch
P|%2|300|0|0|/dev/pts/3|zzz
P|%1|100|5|0|/dev/pts/1|zzz
C|%1|/home/user
C|%3|/home/user
C|%2|/home/user
G|%1|main
G|%1|main
G|%3|
G|%2|
G|%1|'
out=$(run_save_awk "$MIXED_MEMBERSHIP")
assert_eq "one candidate row for the mixed-membership pane" "1" \
	"$(printf '%s\n' "$out" | grep -c .)"
target=$(printf '%s\n' "$out" | cut -f1)
assert_eq "group name survives a later empty G row" "main:0.0" "$target"
MIXED_RESTORE_TABLE='%1|0|0|main
%1|0|0|main-0
%3|0|0|scratch
%2|0|0|zzz
%1|5|0|zzz'
assert_eq "main:0.0 resolves to the mixed-membership pane" "%1" \
	"$(printf '%s\n' "$MIXED_RESTORE_TABLE" | match_pane_id "main" "0" "0")"

echo "-- a pane linked across two different groups must not fall back once the first group's name is gone --"
# A window can be linked into sessions that belong to different tmux
# groups, so one pane can carry more than one distinct nonempty group
# value: here "alpha" (via alpha-0) and "bravo" (via bravo/bravo-0, at a
# different window). Renaming the alpha-group base leaves no membership
# named "alpha", but the pane is still a member of "bravo". Tie policy:
# try each observed group in listing order and take the first one this
# pane has a membership row under; here that is "bravo".
TWO_GROUPS_FIRST_RENAMED='P|%4|100|0|0|/dev/pts/172|alpha-0
P|%4|100|0|0|/dev/pts/172|alpha-renamed
P|%6|300|0|0|/dev/pts/180|bravo
P|%4|100|5|0|/dev/pts/172|bravo
P|%6|300|0|0|/dev/pts/180|bravo-0
P|%4|100|5|0|/dev/pts/172|bravo-0
C|%4|/home/user
C|%4|/home/user
C|%6|/home/user
C|%4|/home/user
C|%6|/home/user
C|%4|/home/user
G|%4|alpha
G|%4|alpha
G|%6|bravo
G|%4|bravo
G|%6|bravo
G|%4|bravo'
out=$(run_save_awk "$TWO_GROUPS_FIRST_RENAMED")
assert_eq "one candidate row for the two-group pane" "1" \
	"$(printf '%s\n' "$out" | grep -c .)"
target=$(printf '%s\n' "$out" | cut -f1)
assert_eq "the second, still-qualifying group is used, not a last-listed fallback" "bravo:5.0" "$target"
TWO_GROUPS_RESTORE_TABLE='%4|0|0|alpha-0
%4|0|0|alpha-renamed
%6|0|0|bravo
%4|5|0|bravo
%6|0|0|bravo-0
%4|5|0|bravo-0'
assert_eq "bravo:5.0 resolves to the two-group pane" "%4" \
	"$(printf '%s\n' "$TWO_GROUPS_RESTORE_TABLE" | match_pane_id "bravo" "5" "0")"

echo "-- when both groups qualify, the earliest-listed one wins --"
# No rename here: this pane has a qualifying membership under both
# "alpha" and "bravo". The tie policy is the listing order the G records
# arrived in, not which membership is more specific or more recent, so
# the expected address is alpha:0.0, not bravo:5.0.
TWO_GROUPS_BOTH_QUALIFY='P|%4|100|0|0|/dev/pts/95|alpha
P|%4|100|0|0|/dev/pts/95|alpha-0
P|%6|300|0|0|/dev/pts/114|bravo
P|%4|100|5|0|/dev/pts/95|bravo
P|%6|300|0|0|/dev/pts/114|bravo-0
P|%4|100|5|0|/dev/pts/95|bravo-0
C|%4|/home/user
C|%4|/home/user
C|%6|/home/user
C|%4|/home/user
C|%6|/home/user
C|%4|/home/user
G|%4|alpha
G|%4|alpha
G|%6|bravo
G|%4|bravo
G|%6|bravo
G|%4|bravo'
out=$(run_save_awk "$TWO_GROUPS_BOTH_QUALIFY")
assert_eq "one candidate row for the both-qualify pane" "1" \
	"$(printf '%s\n' "$out" | grep -c .)"
target=$(printf '%s\n' "$out" | cut -f1)
assert_eq "earliest-listed qualifying group wins" "alpha:0.0" "$target"

echo
echo "target resolution unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
