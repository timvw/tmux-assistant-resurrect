#!/usr/bin/env bash
# Hermetic unit tests for session-less relaunch canonicalization and vouchers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
mkdir -p "$TMUX_RESURRECT_DIR"

# shellcheck source=../scripts/lib-detect.sh
source "$REPO_DIR/scripts/lib-detect.sh"

# Keep voucher resolution independent of options on the developer's live tmux
# server; an unavailable option falls back to TMUX_RESURRECT_DIR.
tmux() { return 1; }

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
assert_true() {
	local desc="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n' "$desc"
	fi
}
assert_false() {
	local desc="$1"
	shift
	if "$@"; then
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n' "$desc"
	else
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	fi
}
noglob_is_set() {
	case "$-" in
	*f*) return 0 ;;
	*) return 1 ;;
	esac
}

echo "== canonicalization =="
canon=$(relaunch_canon claude '/opt/homebrew/bin/claude   agents')
assert_eq "absolute binary path and whitespace collapse" "claude agents" "$canon"
assert_eq "canonicalization is idempotent" "$canon" "$(relaunch_canon claude "$canon")"
assert_eq "Node wrapper script path is removed" "claude agents" \
	"$(relaunch_canon claude 'claude /opt/homebrew/lib/node_modules/@anthropic-ai/claude agents')"
assert_eq "option value ending in the tool name is preserved" \
	"claude --config=/home/user/claude agents" \
	"$(relaunch_canon claude 'claude --config=/home/user/claude agents')"
assert_false "argv[0] must equal the detected tool" relaunch_canon claude 'env claude agents'

echo "== advisory shape filter =="
assert_true "unknown lowercase mode remains a candidate" relaunch_shape_ok 'claude ultrareview'
assert_true "flags plus one positional are eligible" relaunch_shape_ok 'claude --dangerously-skip-permissions agents'
assert_false "bare Claude is refused" relaunch_shape_ok 'claude'
assert_false "bare Pi is refused" relaunch_shape_ok 'pi'
assert_false "prompt flag is refused" relaunch_shape_ok 'claude -p summarize this'
assert_false "API key flag is never written to the ledger" relaunch_shape_ok 'pi --api-key=secret repl'
assert_false "token flag is never written to the ledger" relaunch_shape_ok 'claude --token=secret agents'
assert_false "secret flag is never written to the ledger" relaunch_shape_ok 'copilot --secret-env-vars=TOKEN shell'
assert_false "password flag is never written to the ledger" relaunch_shape_ok 'claude --password=secret agents'
assert_false "auth flag is never written to the ledger" relaunch_shape_ok 'claude --auth-token=secret agents'
assert_false "bare double dash is refused" relaunch_shape_ok 'claude bg-pty-host worker -- claude agents'

long_prompt_2k=""
i=0
while [ "$i" -lt 400 ]; do long_prompt_2k="${long_prompt_2k}word "; i=$((i + 1)); done
long_prompt_8k="$long_prompt_2k$long_prompt_2k$long_prompt_2k$long_prompt_2k"
assert_false "2KB prompt is refused" relaunch_shape_ok "claude $long_prompt_2k"
assert_false "8KB prompt is refused" relaunch_shape_ok "claude $long_prompt_8k"

VOUCHER="$TMUX_RESURRECT_DIR/assistant-relaunch-allow.txt"
: >"$VOUCHER"

echo "== voucher authorization =="
# Load-bearing safety assertion: structural plausibility is never authority.
assert_true "ultrareview passes shape" relaunch_shape_ok 'claude ultrareview'
assert_false "ultrareview is not authorized by an empty voucher" \
	relaunch_voucher_match claude 'claude ultrareview'

printf '# user-owned commands\n\nclaude agents\n' >"$VOUCHER"
assert_eq "exact voucher line matches" "claude agents" \
	"$(relaunch_voucher_match claude 'claude agents')"
assert_false "shorter command does not prefix-match" relaunch_voucher_match claude 'claude agent'
assert_false "sidecar whitespace is not normalized into a match" \
	relaunch_voucher_match claude 'claude  agents'

printf '# comment with trailing spaces   \r\n\r\nclaude gateway\r\nclaude agents   \r\n' >"$VOUCHER"
assert_eq "CRLF voucher line matches" "claude gateway" \
	"$(relaunch_voucher_match claude 'claude gateway')"
assert_false "trailing voucher whitespace is significant" \
	relaunch_voucher_match claude 'claude agents'

printf 'claude REVIEW\n' >"$VOUCHER"
assert_false "shape-rejected command stays out of the advisory ledger path" \
	relaunch_shape_ok 'claude REVIEW'
assert_eq "an exact user voucher remains the sole authorization gate" \
	"claude REVIEW" "$(relaunch_voucher_match claude 'claude REVIEW')"

printf 'claude --x;curl|sh\n' >"$VOUCHER"
assert_eq "metacharacters become one quoted literal argument" \
	"command claude '--x;curl|sh'" \
	"$(relaunch_command_from_voucher claude 'claude --x;curl|sh')"

set -f
relaunch_shape_ok 'claude agents'
assert_true "shape filter preserves caller noglob state" noglob_is_set
relaunch_canon claude 'claude agents' >/dev/null
assert_true "canonicalizer preserves caller noglob state" noglob_is_set
relaunch_command_from_voucher claude 'claude --x;curl|sh' >/dev/null
assert_true "voucher command builder preserves caller noglob state" noglob_is_set
set +f

echo "== advisory ledger retention =="
# Source the guarded save script for relaunch_ledger_apply(). All top-level
# paths remain inside the sandbox via the exported overrides above.
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
# shellcheck source=../scripts/save-assistant-sessions.sh
had_errexit=0
case "$-" in *e*) had_errexit=1 ;; esac
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1
[ "$had_errexit" -eq 1 ] || set +e
now=$(date +%s)
jq -n --argjson now "$now" '
  [range(0;205) | {
    tool:"claude", cmd:("claude mode-" + tostring), seen:1,
    longest_seconds:1, first_seen:"2026-08-26T00:00:00Z",
    last_seen:"2026-08-26T00:00:00Z", last_seen_epoch:($now - .)
  }]
  + [{tool:"claude", cmd:"claude stale", seen:9, longest_seconds:999,
      first_seen:"2026-01-01T00:00:00Z", last_seen:"2026-01-01T00:00:00Z",
      last_seen_epoch:($now - 2678400)}]
' >"$RELAUNCH_LEDGER_FILE"
original_umask=$(umask)
umask 022
relaunch_ledger_apply claude 'claude agents' "$$"
umask "$original_umask"
assert_eq "ledger is capped to 200 recent entries" "200" \
	"$(jq 'length' "$RELAUNCH_LEDGER_FILE")"
assert_eq "entries unseen for more than 30 days are pruned" "0" \
	"$(jq '[.[] | select(.cmd == "claude stale")] | length' "$RELAUNCH_LEDGER_FILE")"
assert_eq "current candidate survives the LRU cap" "1" \
	"$(jq '[.[] | select(.cmd == "claude agents")] | length' "$RELAUNCH_LEDGER_FILE")"
case "$(uname -s)" in
Darwin)
	assert_eq "ledger is written with owner-only permissions" "600" \
		"$(stat -f '%Lp' "$RELAUNCH_LEDGER_FILE")"
	;;
MINGW* | MSYS* | CYGWIN*) ;;
*)
	assert_eq "ledger is written with owner-only permissions" "600" \
		"$(stat -c '%a' "$RELAUNCH_LEDGER_FILE")"
	;;
esac

jq -n --argjson old "$((now - 2678400))" \
	'[{tool:"claude", cmd:"claude agents", seen:99, longest_seconds:999,
	   first_seen:"2026-01-01T00:00:00Z", last_seen:"2026-01-01T00:00:00Z",
	   last_seen_epoch:$old}]' >"$RELAUNCH_LEDGER_FILE"
relaunch_ledger_apply claude 'claude agents' "$$"
assert_eq "a re-observed entry past the prune horizon starts fresh" "1" \
	"$(jq -r '.[0].seen' "$RELAUNCH_LEDGER_FILE")"

printf '%s\n' 'not json' >"$RELAUNCH_LEDGER_FILE"
relaunch_ledger_apply claude 'claude gateway' "$$"
assert_eq "corrupt advisory ledger grants nothing and is rebuilt" "claude gateway" \
	"$(jq -r '.[0].cmd' "$RELAUNCH_LEDGER_FILE")"

echo "== first candidate argv capture =="
# The resolver loops in the current shell, so cand_args ends as the final
# candidate. Pin the separate first_args capture required for relaunch.
get_claude_session() { return 0; }
captured_first_args=""
handle_sessionless_relaunch() {
	captured_first_args="$4"
	return 1
}
unit_us=$'\x1f'
printf -v candidates 'claude%s111%sclaude agents\nclaude%s222%sclaude gateway\n' \
	"$unit_us" "$unit_us" "$unit_us" "$unit_us"
state_cache="$SANDBOX/empty-state-cache"
parts_file="$SANDBOX/empty-parts"
: >"$state_cache"
: >"$parts_file"
resolve_pane_candidates 'test:0.0' /tmp /dev/null "$candidates" "$unit_us" 0 \
	"$state_cache" "$parts_file" test 0 0
assert_eq "resolver relaunches the first BFS candidate argv" \
	"claude agents" "$captured_first_args"
assert_eq "one unresolved pane increments the summary count once" \
	"1" "$UNRESOLVED_PANES"

handle_sessionless_relaunch() { return 0; }
UNRESOLVED_PANES=0
resolve_pane_candidates 'test:0.0' /tmp /dev/null "$candidates" "$unit_us" 0 \
	"$state_cache" "$parts_file" test 0 0
assert_eq "a vouched relaunch is not reported as unresolved" \
	"0" "$UNRESOLVED_PANES"

echo
echo "relaunch unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
