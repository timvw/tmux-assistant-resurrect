# Read a session id from a JSONL file's logical header (jsonl_session_id_from_file).
# Invoked as: python3 jsonl_header_sid.py <session_file>
import json
import sys

MAX_HEADER_BYTES = 1024 * 1024

try:
    with open(sys.argv[1], "rb") as f:
        first = f.readline(MAX_HEADER_BYTES + 1)
        second = f.readline(MAX_HEADER_BYTES + 1)
except Exception:
    sys.exit(0)

for raw in (first, second if first else b""):
    if not raw:
        continue
    if len(raw) > MAX_HEADER_BYTES:
        sys.exit(0)
    try:
        header = json.loads(raw.decode("utf-8"))
    except Exception:
        continue
    if not isinstance(header, dict):
        continue
    if header.get("type") == "title":
        continue
    if header.get("type") != "session":
        sys.exit(0)
    sid = header.get("id")
    if isinstance(sid, str) and sid:
        print(sid)
    sys.exit(0)
