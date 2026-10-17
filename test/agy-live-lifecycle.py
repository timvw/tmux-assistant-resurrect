#!/usr/bin/env python3
"""Opt-in: resume an existing agy conversation across a private tmux restart.

Usage: python3 test/agy-live-lifecycle.py /path/to/tmux-resurrect CONVERSATION_UUID
Uses the current account and local conversation store. Sends no user prompt.
"""

import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "agy_session", ROOT / "scripts/py/agy_session.py"
)
agy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agy)


def main():
    resurrect, sid = Path(sys.argv[1]).resolve(), sys.argv[2]
    if not re.fullmatch(agy.UUID, sid):
        raise SystemExit("CONVERSATION_UUID must be a full UUID")
    binary = shutil.which("agy")
    if not binary:
        raise SystemExit("agy is not installed")
    with tempfile.TemporaryDirectory(prefix="agy-lifecycle-") as temp:
        directory = Path(temp)
        socket = str(directory / "socket")
        env = dict(
            os.environ,
            TMUX=socket + ",0,0",
            TMUX_RESURRECT_DIR=str(directory / "resurrect"),
        )

        def tm(*args):
            return subprocess.check_output(
                ["tmux", "-S", socket, *args], env=env, text=True
            ).strip()

        def configure():
            for key, value in [
                ("default-shell", "/bin/bash"),
                ("default-command", "/bin/bash --noprofile --norc"),
                ("@resurrect-dir", str(directory / "resurrect")),
                ("@resurrect-processes", "false"),
                (
                    "@resurrect-hook-post-save-all",
                    f'bash "{ROOT}/scripts/save-assistant-sessions.sh"',
                ),
                (
                    "@resurrect-hook-post-restore-all",
                    f'bash "{ROOT}/scripts/restore-assistant-sessions.sh"',
                ),
            ]:
                tm("set", "-g", key, value)

        def selected():
            rows = subprocess.check_output(
                ["ps", "-axo", "pid=,ppid=,args="], text=True
            ).splitlines()
            parent = tm("display", "-pt", "agy-test:0.0", "#{pane_pid}")
            for row in rows:
                fields = row.strip().split(None, 2)
                if (
                    len(fields) == 3
                    and fields[1] == parent
                    and Path(fields[2].split()[0]).name == "agy"
                ):
                    result = agy.resolve(fields[0], fields[2])
                    if result == sid:
                        return fields[0]
            return None

        def wait():
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                pid = selected()
                if pid:
                    return pid
                time.sleep(0.2)
            raise AssertionError(
                "agy did not select the requested conversation within 30 seconds"
            )

        def plugin(name):
            subprocess.run(
                ["bash", str(resurrect / "scripts" / name)],
                env=env,
                check=True,
                timeout=60,
                capture_output=True,
            )

        try:
            tm(
                "-f",
                "/dev/null",
                "new",
                "-d",
                "-s",
                "agy-test",
                "-c",
                str(directory),
                "/bin/bash --noprofile --norc",
            )
            configure()
            tm(
                "send",
                "-t",
                "agy-test:0.0",
                "-l",
                shlex.join([binary, "--effort", "high", "--conversation", sid]),
            )
            tm("send", "-t", "agy-test:0.0", "Enter")
            wait()
            plugin("save.sh")
            saved = json.loads(
                (directory / "resurrect/assistant-sessions.json").read_text()
            )["sessions"]
            assert (
                len(saved) == 1
                and saved[0]["tool"] == "agy"
                and saved[0]["session_id"] == sid
            ), saved
            assert saved[0]["cli_args"] == "--effort high", saved
            tm("kill-server")
            tm(
                "-f",
                "/dev/null",
                "new",
                "-d",
                "-s",
                "bootstrap",
                "/bin/bash --noprofile --norc",
            )
            configure()
            plugin("restore.sh")
            pid = wait()
            subprocess.run(
                ["bash", str(ROOT / "scripts/restore-assistant-sessions.sh")],
                env=env,
                check=True,
                timeout=30,
                capture_output=True,
            )
            assert selected() == pid, "repeated restore launched another agent"
            print(
                "PASS: real agy save → tmux restart → resume exact conversation; flags retained; repeated restore skipped"
            )
        finally:
            subprocess.run(
                ["tmux", "-S", socket, "kill-server"], capture_output=True, check=False
            )


if __name__ == "__main__":
    main()
