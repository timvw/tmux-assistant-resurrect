#!/usr/bin/env bash
# Cursor sessionEnd hook — remove the owning CLI process's tracking file.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-cursor-pid.sh
source "$HOOK_DIR/lib-cursor-pid.sh"
# shellcheck source=../scripts/lib-detect.sh
source "$HOOK_DIR/../scripts/lib-detect.sh"

CURSOR_PID=$(find_cursor_pid || true)
[ -n "$CURSOR_PID" ] || exit 0
STATE_DIR="$(assistant_state_dir)"
rm -f "$STATE_DIR/cursor-$CURSOR_PID.json" 2>/dev/null || true
