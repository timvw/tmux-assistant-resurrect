# Read a session id from a JSONL file's logical header (jsonl_session_id_from_file).
# Invoked as: python3 jsonl_header_sid.py <session_file>
import json
import sys

MAX_HEADER_BYTES = 1024 * 1024

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        first = f.readline(MAX_HEADER_BYTES + 1)
        second = f.readline(MAX_HEADER_BYTES + 1)
except Exception:
    sys.exit(0)

for raw in (first, second if first else ""):
    if not raw:
        continue
    if len(raw) > MAX_HEADER_BYTES:
        sys.exit(0)
    try:
        header = json.loads(raw)
    except Exception:
        continue
    if header.get("type") == "title":
        continue
    if header.get("type") != "session":
        sys.exit(0)
    sid = header.get("id")
    if isinstance(sid, str) and sid:
        print(sid)
    sys.exit(0)
