# OpenCode SQLite fallback (get_opencode_session, Method 4).
# Invoked as: python3 opencode_db.py <db_file> <cwd>
# Prints the most recently updated session id whose directory matches cwd.
# The broad `except Exception` guards below are deliberate (hence the noqa):
# this runs inside the save hook against files written by another process,
# and one unreadable or malformed file must be skipped, never propagated.
import os
import sqlite3
import sys
from pathlib import Path

conn = None
try:
    # SQLite URI metacharacters in a perfectly valid path (notably ? and #)
    # must be percent-encoded or SQLite silently opens the wrong filename.
    db_uri = Path(os.path.abspath(sys.argv[1])).as_uri() + "?mode=ro"
    conn = sqlite3.connect(db_uri, uri=True)
    cur = conn.cursor()
    cur.execute(
        "SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1",
        (sys.argv[2],),
    )
    row = cur.fetchone()
    if row and isinstance(row[0], str) and row[0]:
        print(row[0])
except Exception:  # noqa: BLE001, S110
    pass
finally:
    if conn is not None:
        conn.close()
