# Pick the best JSONL session id across one or more session dirs (select_jsonl_session_id).
# Invoked as: python3 select_jsonl_session.py <cwd> <process_start_epoch> <used_ids> <session_dir>...
import datetime
import glob
import json
import os
import sys

MAX_HEADER_BYTES = 1024 * 1024

cwd = sys.argv[1]
start_raw = sys.argv[2].strip()
used = {sid for sid in sys.argv[3].split("\t") if sid}
session_dirs = []
seen_dirs = set()
for session_dir in sys.argv[4:]:
    if not session_dir or not os.path.isdir(session_dir):
        continue
    key = os.path.abspath(session_dir)
    if key in seen_dirs:
        continue
    seen_dirs.add(key)
    session_dirs.append(session_dir)

# Absolute epoch of the assistant process start (empty when undeterminable).
try:
    process_start = float(start_raw) if start_raw else None
except ValueError:
    process_start = None


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def read_logical_header(path):
    with open(path, "rb") as f:
        first = f.readline(MAX_HEADER_BYTES + 1)
        second = f.readline(MAX_HEADER_BYTES + 1)
    for raw in (first, second if first else b""):
        if not raw:
            continue
        if len(raw) > MAX_HEADER_BYTES:
            return None
        header = json.loads(raw.decode("utf-8"))
        if not isinstance(header, dict):
            continue
        if header.get("type") == "title":
            continue
        return header
    return None


candidates = []
for session_dir in session_dirs:
    for path in glob.glob(os.path.join(session_dir, "*.jsonl")):
        try:
            header = read_logical_header(path)
            if not header or header.get("type") != "session":
                continue
            sid = header.get("id")
            if not isinstance(sid, str) or not sid:
                continue
            header_cwd = header.get("cwd")
            if isinstance(header_cwd, str) and header_cwd and header_cwd != cwd:
                continue
            candidates.append(
                (sid, parse_ts(header.get("timestamp")), os.path.getmtime(path))
            )
        except Exception:
            continue

if not candidates:
    sys.exit(0)


def score(item):
    sid, created_at, mtime = item
    reused = sid in used
    if process_start is None:
        active = 0
        prior = 0
        distance = float("inf")
    else:
        active = 1 if mtime >= process_start - 300 else 0
        prior = 1 if created_at is not None and created_at <= process_start + 120 else 0
        distance = (
            abs(process_start - created_at) if created_at is not None else float("inf")
        )
    return (
        0 if reused else 1,
        active,
        prior,
        -distance,
        mtime,
    )


best = max(candidates, key=score)
print(best[0])
