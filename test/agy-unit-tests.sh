#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR"
source "$REPO_DIR/scripts/save-assistant-sessions.sh"
# Avoid depending on any installed agy version's help output.
_tool_help() { return 0; }
assert_eq() {
    if [ "$2" != "$3" ]; then printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2; exit 1; fi
    printf 'PASS %s\n' "$1"
}
assert_eq 'native executable' agy "$(detect_tool '/opt/homebrew/bin/agy --model test')"
assert_eq 'no argument false positive' '' "$(detect_tool 'vim /tmp/agy')"
assert_eq 'production awk detector' agy "$(printf '%s\n' '/opt/homebrew/bin/agy --model test' | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk")"
assert_eq 'production awk rejects argument false positives' '' "$(printf '%s\n' 'vim /tmp/agy' | awk -v classify_only=1 -f "$REPO_DIR/scripts/lib-detect.awk")"
assert_eq 'strip selectors, preserve configuration' '--model test --effort high --dangerously-skip-permissions' "$(extract_cli_args agy 'agy --conversation old --continue --new-project --model test --effort high --dangerously-skip-permissions')"
assert_eq 'do not replay initial prompt' '--model test' "$(extract_cli_args agy 'agy --model test --prompt-interactive do some work --dangerously-skip-permissions')"
assert_eq 'do not reuse process log' '--model test' "$(extract_cli_args agy 'agy --log-file=/tmp/old.log --model test')"
python3 "$REPO_DIR/test/agy-unit-tests.py"
