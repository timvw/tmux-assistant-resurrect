# OpenCode SQLite fallback (get_opencode_session, Method 4).
# Invoked as: python3 opencode_db.py <db_file> <cwd> [<pane_major_version>]
# Prints the most recently updated session id whose directory matches cwd,
# reading OpenCode v2's session_v2 table or v1's session table.
# V1 and V2 can share one database, leaving both tables populated. Then the
# pane's major version picks the table; without it the helper exits with
# NEED_VERSION so the caller resolves the version only when it matters.
# "unknown" falls back to session_v2.
# The broad `except Exception` guards below are deliberate (hence the noqa):
# this runs inside the save hook against files written by another process,
# and one unreadable or malformed file must be skipped, never propagated.
import os
import sqlite3
import sys
from pathlib import Path

NEED_VERSION = 3
V1_QUERY = "SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1"
# Child (subagent) and archived sessions are not resumable top-level
# conversations.
V2_QUERY = (
    "SELECT id FROM session_v2 WHERE directory = ? AND parent_id IS NULL"
    " AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 1"
)

pane_version = sys.argv[3] if len(sys.argv) > 3 else ""
conn = None
exit_code = 0
try:
    # SQLite URI metacharacters in a perfectly valid path (notably ? and #)
    # must be percent-encoded or SQLite silently opens the wrong filename.
    db_uri = Path(os.path.abspath(sys.argv[1])).as_uri() + "?mode=ro"
    conn = sqlite3.connect(db_uri, uri=True)
    cur = conn.cursor()
    tables = {
        name for (name,) in cur.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    query = None
    if "session_v2" in tables and "session" in tables:
        if not pane_version:
            exit_code = NEED_VERSION
        else:
            query = V1_QUERY if pane_version == "1" else V2_QUERY
    elif "session_v2" in tables:
        query = V2_QUERY
    elif "session" in tables:
        query = V1_QUERY
    if query is not None:
        cur.execute(query, (sys.argv[2],))
        row = cur.fetchone()
        if row and isinstance(row[0], str) and row[0]:
            print(row[0])
except Exception:  # noqa: BLE001, S110
    pass
finally:
    if conn is not None:
        conn.close()
sys.exit(exit_code)
