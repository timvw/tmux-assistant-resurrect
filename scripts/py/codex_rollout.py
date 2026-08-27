# Codex rollout session-file lookup (get_codex_session, Method 4).
# Invoked as: USED_CODEX_SESSION_IDS=... python3 codex_rollout.py <sessions_root> <cwd> <process_start_epoch>
import datetime
import json
import os
import sys

MAX_HEADER_BYTES = 1024 * 1024

sessions_root = sys.argv[1]
cwd = sys.argv[2]
start_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

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


candidates = []
for root, _, files in os.walk(sessions_root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, "rb") as f:
                first = f.readline(MAX_HEADER_BYTES + 1)
            if len(first) > MAX_HEADER_BYTES:
                continue
            if not first:
                continue
            record = json.loads(first.decode("utf-8"))
            if record.get("type") != "session_meta":
                continue
            payload = record.get("payload") or {}
            if payload.get("cwd") != cwd:
                continue
            sid = payload.get("id")
            if not isinstance(sid, str) or not sid:
                continue
            candidates.append(
                (sid, parse_ts(payload.get("timestamp")), os.path.getmtime(path))
            )
        except Exception:
            continue

if not candidates:
    sys.exit(0)


def score(item):
    sid, session_start, mtime = item
    reused = sid in used
    if process_start is None or session_start is None:
        prior = 0
        distance = float("inf")
    else:
        prior = 1 if session_start <= process_start + 120 else 0
        distance = abs(process_start - session_start)
    return (
        0 if reused else 1,
        prior,
        -distance,
        mtime,
    )


best = max(candidates, key=score)
print(best[0])
