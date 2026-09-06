"""Resolve Claude Code's newest non-empty transcript for a cwd.

Invoked as: python3 claude_transcript.py <claude-config-dir> <cwd>
    <excluded-session-ids>

Claude Code derives the project directory with JavaScript string semantics:
replace every non-ASCII-alphanumeric UTF-16 code unit with ``-``, then cap a
long result at 200 characters and append its signed 32-bit string hash in
base36.  Mirroring those details matters for underscores, non-ASCII paths, and
astral characters.

This is deliberately best-effort.  The save hook races a live writer, and one
unreadable entry must not prevent every other tmux pane from being saved.
"""

import os
import re
import stat
import sys

SESSION_FILE_RE = re.compile(
    r"^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$"
)


def utf16_units(value):
    raw = value.encode("utf-16-le", errors="surrogatepass")
    return [raw[index] | (raw[index + 1] << 8) for index in range(0, len(raw), 2)]


def base36(value):
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if value == 0:
        return "0"
    result = ""
    while value:
        value, remainder = divmod(value, 36)
        result = digits[remainder] + result
    return result


def project_key(cwd):
    units = utf16_units(cwd)
    sanitized = "".join(
        chr(unit)
        if ord("0") <= unit <= ord("9")
        or ord("A") <= unit <= ord("Z")
        or ord("a") <= unit <= ord("z")
        else "-"
        for unit in units
    )
    if len(sanitized) <= 200:
        return sanitized

    # Claude's hash is `(hash << 5) - hash + charCodeAt(i) | 0`.
    hash_value = 0
    for unit in units:
        hash_value = ((hash_value << 5) - hash_value + unit) & 0xFFFFFFFF
    if hash_value >= 0x80000000:
        hash_value -= 0x100000000
    return f"{sanitized[:200]}-{base36(abs(hash_value))}"


def newest_transcript(config_dir, cwd, excluded):
    project_dir = os.path.join(config_dir, "projects", project_key(cwd))
    newest = None
    try:
        entries = os.scandir(project_dir)
    except OSError:
        return None

    with entries:
        for entry in entries:
            match = SESSION_FILE_RE.match(entry.name)
            if not match:
                continue
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
                continue
            session_id = match.group(1)
            if session_id in excluded:
                continue
            candidate = (info.st_mtime_ns, entry.name, session_id)
            if newest is None or candidate > newest:
                newest = candidate
    return newest[2] if newest else None


if len(sys.argv) == 4:
    excluded_ids = {value for value in sys.argv[3].split("\t") if value}
    session_id = newest_transcript(sys.argv[1], sys.argv[2], excluded_ids)
    if session_id:
        print(session_id)
