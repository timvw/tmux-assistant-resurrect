#!/usr/bin/env bash
# Focused regression tests for hook/plugin installation and helper hardening.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
UNDER_TEST="${BASH:-bash}"

passes=0
failures=0

pass() {
    printf 'PASS: %s\n' "$1"
    passes=$((passes + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

assert_file_mode() {
    local label="$1" expected="$2" path="$3" actual
    if actual=$(stat -f '%Lp' "$path" 2>/dev/null); then
        :
    else
        actual=$(stat -c '%a' "$path")
    fi
    assert_eq "$label" "$expected" "$actual"
}

# Stub only the tmux calls made by the entrypoint and hook. All arguments are
# recorded one per line so hook command values remain inspectable.
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/tmux" <<'TMUX'
#!/usr/bin/env bash
if [ "${1:-}" = "show-option" ]; then
    printf '%s' "${FAKE_TMUX_OPTION:-}"
    exit 0
fi
if [ "${1:-}" = "set-option" ]; then
    printf '%s\n' "$*" >>"$TMUX_CALLS"
fi
TMUX
chmod +x "$FAKE_BIN/tmux"

# The entrypoint must generate executable hook commands even when its checkout
# path contains a single quote, and new config files should be private.
QUOTED_PLUGIN="$TEST_ROOT/plugin's copy"
ln -s "$ROOT_DIR" "$QUOTED_PLUGIN"
INSTALL_HOME="$TEST_ROOT/install-home"
TMUX_CALLS="$TEST_ROOT/tmux-calls"
export TMUX_CALLS
HOME="$INSTALL_HOME" PATH="$FAKE_BIN:$PATH" \
    "$UNDER_TEST" "$QUOTED_PLUGIN/tmux-assistant-resurrect.tmux"
track_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$INSTALL_HOME/.claude/settings.json")
if "$UNDER_TEST" -n -c "$track_cmd" && printf '{}' | HOME="$INSTALL_HOME" PATH="$FAKE_BIN:$PATH" "$UNDER_TEST" -c "$track_cmd"; then
    pass "quoted checkout path produces an executable Claude hook command"
else
    fail "quoted checkout path produces an executable Claude hook command"
fi
assert_file_mode "new Claude settings are private" 600 "$INSTALL_HOME/.claude/settings.json"

save_cmd=$(sed -n 's/^set-option -g @resurrect-hook-post-save-all //p' "$TMUX_CALLS")
if "$UNDER_TEST" -n -c "$save_cmd"; then
    pass "quoted checkout path produces a valid tmux save hook"
else
    fail "quoted checkout path produces a valid tmux save hook"
fi

# Missing jq should be a true no-op for Claude configuration, rather than
# creating an empty settings file that this invocation cannot safely update.
NO_JQ_BIN="$TEST_ROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for utility in bash dirname ln mkdir readlink sed; do
    ln -s "$(command -v "$utility")" "$NO_JQ_BIN/$utility"
done
ln -s "$FAKE_BIN/tmux" "$NO_JQ_BIN/tmux"
NO_JQ_HOME="$TEST_ROOT/no-jq-home"
HOME="$NO_JQ_HOME" PATH="$NO_JQ_BIN" \
    "$UNDER_TEST" "$ROOT_DIR/tmux-assistant-resurrect.tmux"
if [ ! -e "$NO_JQ_HOME/.claude/settings.json" ]; then
    pass "missing jq does not create an unusable Claude settings file"
else
    fail "missing jq does not create an unusable Claude settings file"
fi

# A colliding regular plugin file is user data and must not be overwritten.
COLLISION_HOME="$TEST_ROOT/collision-home"
mkdir -p "$COLLISION_HOME/.config/opencode/plugins"
printf 'user plugin\n' >"$COLLISION_HOME/.config/opencode/plugins/session-tracker.js"
HOME="$COLLISION_HOME" PATH="$FAKE_BIN:$PATH" \
    "$UNDER_TEST" "$ROOT_DIR/tmux-assistant-resurrect.tmux" 2>/dev/null
assert_eq "OpenCode regular-file collision is preserved" "user plugin" \
    "$(sed -n '1p' "$COLLISION_HOME/.config/opencode/plugins/session-tracker.js")"

# ln -sf follows a destination symlink-to-directory on common platforms. The
# installer must replace that symlink itself rather than writing into its target.
SYMLINK_HOME="$TEST_ROOT/symlink-home"
SYMLINK_TARGET="$TEST_ROOT/unrelated-directory"
mkdir -p "$SYMLINK_HOME/.config/opencode/plugins" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_HOME/.config/opencode/plugins/session-tracker.js"
HOME="$SYMLINK_HOME" PATH="$FAKE_BIN:$PATH" \
    "$UNDER_TEST" "$ROOT_DIR/tmux-assistant-resurrect.tmux"
if [ -L "$SYMLINK_HOME/.config/opencode/plugins/session-tracker.js" ] && \
   [ ! -e "$SYMLINK_TARGET/opencode-session-track.js" ]; then
    pass "OpenCode installer does not follow a destination directory symlink"
else
    fail "OpenCode installer does not follow a destination directory symlink"
fi

# Claude state writes ignore malformed capture-env names, are valid JSON, and
# remain private even when the configured state directory itself is shared.
cat >"$FAKE_BIN/ps" <<'PS'
#!/usr/bin/env bash
case " $* " in
    *' comm= '*) printf 'claude\n' ;;
    *' ppid= '*) printf '1\n' ;;
esac
PS
chmod +x "$FAKE_BIN/ps"
CLAUDE_STATE="$TEST_ROOT/claude-state"
mkdir -m 0755 "$CLAUDE_STATE"
FAKE_TMUX_OPTION='GOOD_ENV BAD-NAME 9INVALID' \
GOOD_ENV='captured value' \
TMUX_ASSISTANT_RESURRECT_DIR="$CLAUDE_STATE" \
PATH="$FAKE_BIN:$PATH" \
    "$UNDER_TEST" "$ROOT_DIR/hooks/claude-session-track.sh" <<<'{"session_id":"claude-test"}'
claude_file=$(find "$CLAUDE_STATE" -name 'claude-*.json' -type f -print -quit)
assert_eq "Claude hook captures valid environment names" "captured value" \
    "$(jq -r '.env.GOOD_ENV' "$claude_file")"
assert_eq "Claude hook skips invalid environment names" false \
    "$(jq '(.env | has("BAD-NAME")) or (.env | has("9INVALID"))' "$claude_file")"
assert_file_mode "Claude state file is private" 600 "$claude_file"
assert_eq "Claude state write leaves no temporary file" 0 \
    "$(find "$CLAUDE_STATE" -name '*.tmp' -o -name '.claude-*' | wc -l | tr -d ' ')"

# OpenCode writes use a private temporary inode followed by atomic rename.
OPEN_STATE="$TEST_ROOT/open state"
mkdir -m 0755 "$OPEN_STATE"
MODULE_COPY="$TEST_ROOT/opencode-session-track.mjs"
cp "$ROOT_DIR/hooks/opencode-session-track.js" "$MODULE_COPY"
MODULE_URL=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$MODULE_COPY")
node_result=$(MODULE_URL="$MODULE_URL" TMUX_ASSISTANT_RESURRECT_DIR="$OPEN_STATE" \
    PATH="$FAKE_BIN:$PATH" node --input-type=module <<'NODE'
import { statSync, readFileSync, readdirSync } from "fs";
const { SessionTracker } = await import(process.env.MODULE_URL);
const plugin = await SessionTracker({ client: {}, directory: "/work" });
await plugin.event({ event: { type: "session.updated", properties: { info: { id: "open-test" } } } });
const file = `${process.env.TMUX_ASSISTANT_RESURRECT_DIR}/opencode-${process.pid}.json`;
const mode = (statSync(file).mode & 0o777).toString(8);
const data = JSON.parse(readFileSync(file, "utf8"));
const temps = readdirSync(process.env.TMUX_ASSISTANT_RESURRECT_DIR).filter((name) => name.endsWith(".tmp")).length;
console.log(`${mode}\t${data.session_id}\t${temps}`);
NODE
)
assert_eq "OpenCode state write is private, valid, and atomic" $'600\topen-test\t0' "$node_result"

# A plugin must not turn SIGTERM into a successful process exit. This subprocess
# stays alive after plugin initialization so the observed status is signal-based.
TMUX_ASSISTANT_RESURRECT_DIR="$OPEN_STATE" MODULE_URL="$MODULE_URL" \
    PATH="$FAKE_BIN:$PATH" node --input-type=module <<'NODE' &
const { SessionTracker } = await import(process.env.MODULE_URL);
const plugin = await SessionTracker({ client: {}, directory: "/work" });
await plugin.event({ event: { type: "session.created", properties: { id: "signal-test" } } });
setInterval(() => {}, 1000);
NODE
node_pid=$!
signal_state="$OPEN_STATE/opencode-$node_pid.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$signal_state" ] && break
    sleep 0.1
done
kill -TERM "$node_pid"
set +e
wait "$node_pid" 2>/dev/null
node_status=$?
set -e
assert_eq "OpenCode plugin preserves SIGTERM exit semantics" 143 "$node_status"
if [ ! -e "$signal_state" ]; then
    pass "OpenCode plugin removes state before signal termination"
else
    fail "OpenCode plugin removes state before signal termination"
fi

# SQLite read-only URIs must encode valid filename metacharacters.
DB_ROOT="$TEST_ROOT/db?#files"
mkdir -p "$DB_ROOT/codex"
python3 - "$DB_ROOT/opencode?#.sqlite" "$DB_ROOT/codex/state_1.sqlite" <<'PY'
import sqlite3
import sys

open_db = sqlite3.connect(sys.argv[1])
open_db.execute("CREATE TABLE session (id TEXT, directory TEXT, time_updated INTEGER)")
open_db.execute("INSERT INTO session VALUES (?, ?, ?)", ("open-db-test", "/work", 10))
open_db.commit()
open_db.close()

codex_db = sqlite3.connect(sys.argv[2])
codex_db.execute("CREATE TABLE threads (id TEXT, cwd TEXT, updated_at REAL, archived INTEGER)")
codex_db.execute("INSERT INTO threads VALUES (?, ?, ?, ?)", ("codex-db-test", "/work", 20, 0))
codex_db.commit()
codex_db.close()
PY
assert_eq "OpenCode DB helper supports URI metacharacters" open-db-test \
    "$(python3 "$ROOT_DIR/scripts/py/opencode_db.py" "$DB_ROOT/opencode?#.sqlite" /work)"
assert_eq "Codex DB helper supports URI metacharacters" codex-db-test \
    "$(python3 "$ROOT_DIR/scripts/py/codex_state_db.py" "$DB_ROOT/codex" /work 10)"

# Non-finite SQLite values compare surprisingly (NaN is never less than a
# finite process start). They must not outrank a valid thread.
python3 - "$DB_ROOT/codex/state_2.sqlite" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE threads (id TEXT, cwd TEXT, updated_at, archived INTEGER)")
db.executemany(
    "INSERT INTO threads VALUES (?, ?, ?, ?)",
    [
        ("codex-nan", "/work", "nan", 0),
        ("codex-inf", "/work", "inf", 0),
        ("codex-finite", "/work", 20, 0),
    ],
)
db.commit()
db.close()
PY
assert_eq "Codex DB helper rejects non-finite update times" codex-finite \
    "$(python3 "$ROOT_DIR/scripts/py/codex_state_db.py" "$DB_ROOT/codex" /work 10)"

# Session roots are user-writable and may contain corrupt files. Bound logical
# header reads so one giant unterminated line cannot force unbounded allocation.
OVERSIZED_DIR="$TEST_ROOT/oversized-jsonl"
mkdir -p "$OVERSIZED_DIR"
python3 - "$OVERSIZED_DIR/session.jsonl" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write("x" * (1024 * 1024 + 1))
PY
assert_eq "JSONL header helper rejects oversized records" "" \
    "$(python3 "$ROOT_DIR/scripts/py/jsonl_header_sid.py" "$OVERSIZED_DIR/session.jsonl")"
assert_eq "JSONL selector rejects oversized records" "" \
    "$(python3 "$ROOT_DIR/scripts/py/select_jsonl_session.py" /work 10 '' "$OVERSIZED_DIR")"
assert_eq "Codex rollout lookup rejects oversized records" "" \
    "$(python3 "$ROOT_DIR/scripts/py/codex_rollout.py" "$OVERSIZED_DIR" /work 10)"
: >"$OVERSIZED_DIR/empty.jsonl"
assert_eq "JSONL header helper handles an empty binary file" "" \
    "$(python3 "$ROOT_DIR/scripts/py/jsonl_header_sid.py" "$OVERSIZED_DIR/empty.jsonl")"

# The bound is bytes, not decoded characters: a valid UTF-8 header containing
# multibyte text must still be rejected once its on-disk line exceeds 1 MiB.
MULTIBYTE_SESSION_DIR="$TEST_ROOT/multibyte-session"
MULTIBYTE_CODEX_DIR="$TEST_ROOT/multibyte-codex"
mkdir -p "$MULTIBYTE_SESSION_DIR" "$MULTIBYTE_CODEX_DIR"
python3 - "$MULTIBYTE_SESSION_DIR/session.jsonl" "$MULTIBYTE_CODEX_DIR/rollout.jsonl" <<'PY'
import json
import sys

padding = "é" * 600_000
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(json.dumps({"type": "session", "id": "too-large", "cwd": "/work", "padding": padding}, ensure_ascii=False) + "\n")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write(json.dumps({"type": "session_meta", "payload": {"id": "too-large", "cwd": "/work", "padding": padding}}, ensure_ascii=False) + "\n")
PY
assert_eq "JSONL header helper applies its limit to raw UTF-8 bytes" "" \
    "$(python3 "$ROOT_DIR/scripts/py/jsonl_header_sid.py" "$MULTIBYTE_SESSION_DIR/session.jsonl")"
assert_eq "JSONL selector applies its limit to raw UTF-8 bytes" "" \
    "$(python3 "$ROOT_DIR/scripts/py/select_jsonl_session.py" /work 10 '' "$MULTIBYTE_SESSION_DIR")"
assert_eq "Codex rollout lookup applies its limit to raw UTF-8 bytes" "" \
    "$(python3 "$ROOT_DIR/scripts/py/codex_rollout.py" "$MULTIBYTE_CODEX_DIR" /work 10)"

# Schema drift is expected for versioned Codex databases and must be a quiet,
# successful fallback so the rollout lookup can run next.
BAD_CODEX="$TEST_ROOT/bad-codex"
mkdir -p "$BAD_CODEX"
python3 - "$BAD_CODEX/state_99.sqlite" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE future_schema (id TEXT)")
db.close()
PY
if bad_output=$(python3 "$ROOT_DIR/scripts/py/codex_state_db.py" "$BAD_CODEX" /work 10 2>&1); then
    assert_eq "Codex DB schema drift is a quiet fallback" "" "$bad_output"
else
    fail "Codex DB schema drift is a quiet fallback"
fi

# The status recipe must inspect the same custom resurrect directory as the
# save/restore hooks instead of reporting only the legacy ~/.tmux location.
STATUS_HOME="$TEST_ROOT/status-home"
STATUS_RESURRECT="$TEST_ROOT/custom-resurrect"
mkdir -p "$STATUS_HOME" "$STATUS_RESURRECT"
cat >"$STATUS_RESURRECT/assistant-sessions.json" <<'JSON'
{"timestamp":"2026-08-27T00:00:00Z","sessions":[{"tool":"claude","pane":"work:0.0","session_id":"status-test"}]}
JSON
if command -v just >/dev/null 2>&1; then
    status_output=$(HOME="$STATUS_HOME" TMUX_RESURRECT_DIR="$STATUS_RESURRECT" \
        just --justfile "$ROOT_DIR/justfile" --working-directory "$ROOT_DIR" status)
    case "$status_output" in
        *'Last save: 2026-08-27T00:00:00Z (1 session(s))'*'claude in work:0.0: status-test'*)
            pass "status reads assistant sessions from resurrect_data_dir"
            ;;
        *)
            fail "status reads assistant sessions from resurrect_data_dir"
            ;;
    esac
else
    printf 'SKIP: status resolver test (just is unavailable)\n'
fi

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
