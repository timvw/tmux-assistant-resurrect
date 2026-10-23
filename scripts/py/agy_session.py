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
PROMPT = re.compile(r"(?:^|\s)(--prompt-interactive|--prompt|--print|-i|-p)(?:[=\s]|$)")


def before_prompt(args):
    """ps flattens the prompt too; nothing after its first flag is an option."""
    return PROMPT.split(args, maxsplit=1)[0]


def exact_argv(pid):
    """Keep kernel argv boundaries, including newlines inside one element."""
    if not str(pid).isdigit() or int(pid) <= 1:
        return None
    try:
        words = [
            os.fsdecode(word)
            for word in (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
        ]
    except OSError:
        return None
    if words and words[-1] == "":
        words.pop()
    if words and Path(words[0]).name == "agy":
        return words[1:]
    if (
        len(words) > 1
        and Path(words[0]).name
        in {"node", "nodejs", "bun", "deno", "bash", "sh", "dash", "ksh", "zsh"}
        and Path(words[1]).name == "agy"
    ):
        return words[2:]
    return None


def replay_args(pid, args, value_flags):
    """Strip transient options before flattening; retain complete replay values."""
    words = exact_argv(pid)
    exact = words is not None
    if not exact:
        words = before_prompt(args).split()[1:]
        if words and Path(words[0]).name == "agy":
            words.pop(0)
    out = []
    i = 0
    while i < len(words):
        word = words[i]
        flag, equals, value = word.partition("=")
        if flag in {"--prompt-interactive", "--prompt", "--print", "-i", "-p", "--"}:
            break
        if not word.startswith("-"):
            break
        i += 1
        if flag in {"--continue", "-c", "--new-project"}:
            continue
        if flag in value_flags:
            if not equals:
                if i == len(words):
                    break
                value = words[i]
                i += 1
            if not exact and flag == "--log-file":
                # agy's discarded log path may have spaces.
                # Consume the entire flattened value, never strand its tail
                # as a positional that drops later --sandbox / --mode flags.
                # Do not apply this to ordinary replay options: their bare
                # tail may be a positional prompt, not a split value.
                while i < len(words) and not words[i].startswith("-"):
                    value += " " + words[i]
                    i += 1
            if flag in {"--conversation", "--log-file"}:
                continue
            # The sidecar cannot represent a whitespace-containing value.
            # Omit the whole option, never a partial path or fabricated flag.
            if not value or any(c.isspace() for c in value):
                continue
            out.extend([flag + "=" + value] if equals else [flag, value])
        elif not any(c.isspace() for c in word):
            out.append(word)
    return " ".join(out)


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
    args = before_prompt(args)
    match = re.search(r"(?:^|\s)" + re.escape(name) + r"(?:=|\s+)(\S+)", args)
    return match.group(1) if match else ""


def log_paths(pid, args, cwd=""):
    """Read only logs actually open in this process, including --log-file."""
    if not str(pid).isdigit() or int(pid) <= 1:
        return []
    paths = set()
    proc = Path("/proc") / str(pid) / "fd"
    if proc.is_dir():
        try:
            cwd = os.readlink(proc.parent / "cwd")
        except OSError:
            pass
        for fd in proc.iterdir():
            try:
                paths.add(os.readlink(fd))
            except OSError:
                pass
    else:
        try:
            # -n/-P: only file paths are needed. Without them lsof resolves
            # every socket's host and port name first, which can outlast the
            # timeout when reverse DNS is slow and lose a live session.
            result = subprocess.run(
                ["lsof", "-n", "-P", "-a", "-p", str(pid), "-F0fn"],
                capture_output=True,
                timeout=5,
                check=False,
            )
            fd = ""
            for field in result.stdout.split(b"\0"):
                field = field.lstrip(b"\n")
                if field.startswith(b"f"):
                    fd = os.fsdecode(field[1:])
                elif field.startswith(b"n/"):
                    path = os.fsdecode(field[1:])
                    if fd == "cwd":
                        cwd = path
                    else:
                        paths.add(path)
        except (OSError, subprocess.TimeoutExpired):
            return []

    custom = []
    words = exact_argv(pid)
    if words is not None:
        for i, word in enumerate(words):
            if word.split("=", 1)[0] in {
                "--prompt-interactive",
                "--prompt",
                "--print",
                "-i",
                "-p",
            }:
                break
            if word.startswith("--log-file="):
                custom.append(word.split("=", 1)[1])
            elif word == "--log-file" and i + 1 < len(words):
                custom.append(words[i + 1])
    else:
        # Try complete prefixes, longest first. Verify against the PID's open
        # files instead of guessing where a flattened path with spaces ends.
        launch = before_prompt(args)
        for match in re.finditer(r"(?:^|\s)--log-file(?:=|\s+)", launch):
            tail = launch[match.end() :]
            ends = [len(tail)] + [m.start() for m in re.finditer(r"\s+-", tail)]
            custom.extend(tail[:end] for end in sorted(ends, reverse=True))

    def is_log(path):
        if "/antigravity-cli/log/cli-" in path and path.endswith(".log"):
            return True
        for value in custom:
            # lsof paths are POSIX, including in the Windows canary fixtures.
            # Exact strings need no host-specific pathlib normalization.
            if value == path:
                return True
            candidate = Path(value)
            if not candidate.is_absolute():
                if not cwd:
                    continue
                candidate = Path(cwd) / candidate
            try:
                if candidate.samefile(path):
                    return True
            except OSError:
                pass
        return False

    return sorted(p for p in paths if is_log(p) and Path(p).is_file())


def resolve(pid, args, cwd=""):
    prompt = PROMPT.search(args)
    if prompt and prompt.group(1) in {"--print", "--prompt", "-p"}:
        return ""
    selections = [selected_session(path) for path in log_paths(pid, args, cwd)]
    active = {session for seen, session in selections if seen}
    # A new/cleared conversation must not fall back to stale launch argv.
    if active:
        return active.pop() if len(active) == 1 else ""
    sid = option(args, "--conversation")
    return sid if re.fullmatch(UUID, sid) else ""


if __name__ == "__main__":
    if sys.argv[1] == "--replay":
        result = replay_args(sys.argv[2], sys.argv[3], set(sys.argv[4].split()))
    else:
        result = resolve(
            sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
        )
    if result:
        print(result)
