#!/usr/bin/env python3
"""Resolve Antigravity CLI's selected conversation from its PID-owned log.

No directory/mtime guessing: several agy processes may share one workspace.
The log format is an observed CLI contract, not a documented public API.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

UUID = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
SELECTED = re.compile(
    r"(?:Streaming conversation |Starting conversation update stream for )("
    + UUID
    + r")\b"
)
REDRAW = re.compile(
    r"Full redraw completed \([^\n]*\) for conversation (" + UUID + r")?\s*\(epoch"
)


def selected_session(path):
    """Return (saw selection event, id); an empty redraw clears an older id."""
    seen, session = False, ""
    try:
        with Path(path).open(errors="replace") as log:
            for line in log:
                match = SELECTED.search(line) or REDRAW.search(line)
                if match:
                    seen, session = True, match.group(1) or ""
    except OSError:
        pass
    return seen, session


def option(args, name):
    # ps loses quoting. The UUID form is unambiguous; paths containing spaces
    # are discovered from the live file descriptors instead of split here.
    args = re.split(
        r"(?:^|\s)(?:--prompt-interactive|--prompt|--print|-i|-p)(?:[=\s]|$)",
        args,
        maxsplit=1,
    )[0]
    match = re.search(r"(?:^|\s)" + re.escape(name) + r"(?:=|\s+)(\S+)", args)
    return match.group(1) if match else ""


def log_paths(pid, args):
    """Read only logs actually open in this process, including --log-file."""
    if not str(pid).isdigit() or int(pid) <= 1:
        return []
    paths = set()
    proc = Path("/proc") / str(pid) / "fd"
    if proc.is_dir():
        for fd in proc.iterdir():
            try:
                paths.add(os.readlink(fd))
            except OSError:
                pass
    else:
        try:
            result = subprocess.run(
                ["lsof", "-a", "-p", str(pid), "-F0n"],
                capture_output=True,
                timeout=5,
                check=False,
            )
            paths = {
                os.fsdecode(field[1:])
                for field in result.stdout.split(b"\0")
                if field.startswith(b"n/")
            }
        except (OSError, subprocess.TimeoutExpired):
            return []

    def is_log(path):
        if "/antigravity-cli/log/cli-" in path and path.endswith(".log"):
            return True
        # Compare the complete open path against flattened ps argv; splitting
        # the option value would lose custom log paths containing spaces.
        return bool(
            re.search(
                r"(?:^|\s)--log-file(?:=|\s+)" + re.escape(path) + r"(?=\s+-|$)", args
            )
        )

    return sorted(p for p in paths if is_log(p) and Path(p).is_file())


def resolve(pid, args):
    if re.search(r"(?:^|\s)(?:--print|--prompt|-p)(?:[=\s]|$)", args):
        return ""
    selections = [selected_session(path) for path in log_paths(pid, args)]
    active = {session for seen, session in selections if seen}
    # A new/cleared conversation must not fall back to stale launch argv.
    if active:
        return active.pop() if len(active) == 1 else ""
    sid = option(args, "--conversation")
    return sid if re.fullmatch(UUID, sid) else ""


if __name__ == "__main__":
    result = resolve(sys.argv[1], sys.argv[2])
    if result:
        print(result)
