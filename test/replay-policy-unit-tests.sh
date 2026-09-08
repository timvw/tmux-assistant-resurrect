#!/usr/bin/env bash
# Hermetic replay exclusions, including exact argv and old-sidecar behavior.
# shellcheck disable=SC2034 # policy globals are read by sourced functions
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR"
tmux() {
	case "${3:-}" in
	@assistant-resurrect-claude-drop-flags) printf '%s' "${TEST_CLAUDE_FLAGS:-}" ;;
	@assistant-resurrect-claude-drop-env) printf '%s' "${TEST_CLAUDE_ENV:-}" ;;
	*) return 1 ;;
	esac
}
# shellcheck source=../scripts/save-assistant-sessions.sh
source "$REPO_DIR/scripts/save-assistant-sessions.sh"
set +e
_tool_help() {
	case "$1" in
	claude) printf '  --settings <settings>  Settings document\n  --verbose  Debug output\n  --model <model>  Model\n  --add-dir <directories...>  Directories\n' ;;
	codex) printf '  -m, --model <MODEL>  Model\n' ;;
	pi) printf '  -t, --tools <tools>  Tools\n' ;;
	esac
}
PASS=0 FAIL=0
assert_eq() {
	if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '[pass] %s\n' "$1"
	else FAIL=$((FAIL+1)); printf '[FAIL] %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}

DROP_FLAGS=--model
assert_eq 'all adjacent occurrences disappear' '--verbose' \
	"$(extract_cli_args claude 'claude --model opus --model sonnet --model=haiku --verbose')"
assert_eq 'long rule removes a short alias' '--verbose' \
	"$(extract_cli_args codex 'codex -m opus --verbose')"
assert_eq 'short alias with equals' '--verbose' \
	"$(extract_cli_args codex 'codex -m=opus --verbose')"
assert_eq 'attached short value is removed with the flag' '--verbose' \
	"$(extract_cli_args codex 'codex -mopus --verbose')"
DROP_FLAGS=-m
assert_eq 'short rule removes the long alias' '--verbose' \
	"$(extract_cli_args codex 'codex --model opus --verbose')"
assert_eq 'short alias is scoped to its assistant' '--model opus --verbose' \
	"$(extract_cli_args claude 'claude --model opus --verbose')"

DROP_FLAGS=--verbose
assert_eq 'a removed boolean never promotes prompt text' '' \
	"$(extract_cli_args claude 'claude --verbose explain --dangerously-skip-permissions')"
assert_eq 'a removed boolean leaves a following option' '--model opus' \
	"$(extract_cli_args claude 'claude --verbose --model opus')"
DROP_FLAGS=--add-dir
assert_eq 'all variadic values disappear without losing the tail' '--model opus --verbose' \
	"$(extract_cli_args claude 'claude --add-dir /tmp/a /tmp/b --model opus --verbose')"
DROP_FLAGS='--model --model not-an-option --bad.*'
assert_eq 'invalid entries are ignored and duplicates are harmless' '--verbose' \
	"$(extract_cli_args claude 'claude --model opus --verbose' 2>/dev/null)"

TEST_CLAUDE_FLAGS=--settings
TEST_CLAUDE_ENV='ANTHROPIC_MODEL DUPLICATE'
replay_load_tool_policy claude
DROP_FLAGS=--model
assert_eq 'global and per-assistant rules form a union' '--verbose' \
	"$(extract_cli_args claude 'claude --model opus --settings theme.json --verbose')"
assert_eq 'per-assistant rule does not affect another tool' '--settings=theme.json --verbose' \
	"$(extract_cli_args pi 'pi --settings=theme.json --verbose')"

# Inject the same NUL-delimited stream that /proc supplies, keeping JSON and
# embedded newlines inside a single value. No real assistant or Linux needed.
_exact_argv() {
	printf '%s\0' --settings '{"theme": "old pane"}' --verbose --model opus
}
assert_eq 'explicit settings removal precedes exact-argv restriction checks' '--verbose' \
	"$(extract_cli_args claude 'claude --settings JSON --verbose --model opus' 123)"
_exact_argv() {
	printf '%s\0' --settings $'{"theme":"old\npane"}' --verbose
}
assert_eq 'a dropped exact value cannot fabricate a new argument' '--verbose' \
	"$(extract_cli_args claude 'claude --settings JSON --verbose' 123)"
_exact_argv() {
	printf '%s\0' --settings --dangerously-skip-permissions --verbose
}
assert_eq 'a required dash-leading value is removed with its option' '--verbose' \
	"$(extract_cli_args claude 'claude --settings VALUE --verbose' 123)"
_REPLAY_DROP_FLAGS_claude='--settings --debug'
_exact_argv() { printf '%s\0' --debug --verbose; }
assert_eq 'an absent optional value does not eat the next flag' '--verbose' \
	"$(extract_cli_args claude 'claude --debug --verbose' 123)"
_exact_argv() { return 0; }

DROP_ENV='DUPLICATE GLOBAL 123INVALID'
assert_eq 'environment union is deduplicated and validated' 'DUPLICATE GLOBAL ANTHROPIC_MODEL' \
	"$(replay_drop_names claude env 2>/dev/null)"
assert_eq 'drop wins over captured values and preserves unrelated variables' '{"KEEP":"yes"}' \
	"$(replay_filter_env claude '{"GLOBAL":"secret","ANTHROPIC_MODEL":"opus","KEEP":"yes"}' 2>/dev/null)"
assert_eq 'missing environment stays null' null "$(replay_filter_env claude null 2>/dev/null)"

# Exercise both save producers: metadata must not revive --model in either
# the production batched path or the compatibility emitter.
DROP_ENV=ANTHROPIC_MODEL
get_claude_session() { echo sid-review; }
printf '%s\n' '{"model":"opus","env":{"ANTHROPIC_MODEL":"opus","KEEP":"yes"}}' >"$STATE_DIR/claude-999999.json"
PARTS_FILE="$SANDBOX/parts.json"
emit_session review:0.0 claude 999999 'claude --model opus --verbose' "$SANDBOX"
assert_eq 'compatibility emitter removes the model fallback' '' "$(jq -r .model "$PARTS_FILE")"
assert_eq 'compatibility emitter removes excluded environment' '{"KEEP":"yes"}' "$(jq -c .env "$PARTS_FILE")"
: >"$PARTS_FILE"
resolve_pane_candidates review:0.0 "$SANDBOX" /dev/pts/1 \
	$'claude\x1f999999\x1fclaude --model opus --verbose' $'\x1f' 0 "$SANDBOX/no-cache" "$PARTS_FILE" review 0 0
assert_eq 'batched producer removes the model fallback' '' "$(awk -F '\t' '{print $6}' "$PARTS_FILE")"
assert_eq 'batched producer removes excluded environment' '{"KEEP":"yes"}' "$(awk -F '\t' '{print $8}' "$PARTS_FILE")"

DROP_FLAGS='' DROP_ENV=''
_REPLAY_DROP_FLAGS_claude='' _REPLAY_DROP_ENV_claude=''
assert_eq 'empty policy preserves replay flags' '--model opus --verbose' \
	"$(extract_cli_args claude 'claude --model opus --verbose')"
printf '\nreplay policy unit tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
