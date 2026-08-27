# Codex thread-state SQLite lookup (get_codex_session, Method 3).
# Invoked as: USED_CODEX_SESSION_IDS=... python3 codex_state_db.py <codex_home> <cwd> <process_start_epoch>
import glob
import os
import sqlite3
import sys
from pathlib import Path

codex_home = sys.argv[1]
cwd = sys.argv[2]
start_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

# Find the newest state_*.sqlite by mtime.
dbs = sorted(
    glob.glob(os.path.join(codex_home, "state_*.sqlite")),
    key=os.path.getmtime,
    reverse=True,
)
if not dbs:
    sys.exit(0)

# Absolute epoch of the assistant process start (empty on platforms where it
# can't be determined, in which case matching falls back to most-recent).
try:
    process_start = float(start_raw) if start_raw else None
except ValueError:
    process_start = None

# Open read-only so we never conflict with a running codex writer.
try:
    db_uri = Path(os.path.abspath(dbs[0])).as_uri() + "?mode=ro"
    con = sqlite3.connect(db_uri, uri=True)
except sqlite3.Error:
    sys.exit(0)

try:
    cur = con.cursor()
    try:
        cur.execute(
            "SELECT id, updated_at FROM threads "
            "WHERE cwd = ? AND archived = 0 "
            "ORDER BY updated_at DESC",
            (cwd,),
        )
        rows = cur.fetchall()
    except sqlite3.Error:
        # Codex versions its state DB when schemas change. An unknown or
        # partially migrated schema is a normal fallback condition, not a
        # reason to abort the parent save hook.
        rows = []
finally:
    con.close()


# Prefer threads whose last update happened after the process started
# (rules out stale threads in the same cwd). Fall back to most-recent
# overall if nothing qualifies — covers the edge case where a session
# was spawned but hasn't had any user turns yet.
def pick(rows, require_after_start):
    for sid, updated_at in rows:
        if not isinstance(sid, str) or not sid:
            continue
        if sid in used:
            continue
        if require_after_start and process_start is not None:
            try:
                if float(updated_at) < process_start:
                    continue
            except (TypeError, ValueError):
                continue
        return sid
    return None


sid = pick(rows, require_after_start=True) or pick(rows, require_after_start=False)
if sid:
    print(sid)
