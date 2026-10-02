#!/usr/bin/env python3
"""Real OpenCode V1/V2 plugin contract; no login, prompts, or live dotfiles.

Usage: python3 test/opencode-plugin-contract-test.py /path/to/v1/opencode /path/to/v2/opencode
Install the binaries in separate temporary npm prefixes. Requires POSIX process
groups (Linux/macOS), bash, jq, and Node/Bun as required by the supplied binaries.
"""

import base64
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


REPO = Path(__file__).resolve().parent.parent
ERROR = "Plugin must export a default definition with an id and an effect or setup function."


def wait_for(read, predicate, label):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            value = read()
            if predicate(value):
                return value
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {label}")


@contextlib.contextmanager
def server(binary, home, env):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    # Only a throwaway local password; credentials never leave this process.
    headers = {
        "Authorization": "Basic "
        + base64.b64encode(b"opencode:isolated-contract-test").decode(),
        "Content-Type": "application/json",
    }

    def request(route, method="GET", body=None):
        url = f"http://127.0.0.1:{port}{route}?directory={urllib.parse.quote(str(home))}"
        req = urllib.request.Request(
            url,
            headers=headers,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
        )
        with urllib.request.urlopen(req, timeout=3) as response:
            return json.load(response)

    with (home / "server.log").open("w") as log:
        proc = subprocess.Popen(
            [str(binary), "serve", "--hostname", "127.0.0.1", "--port", str(port)],
            env=env,
            cwd=home,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
        try:
            yield request
        finally:
            # Kill only the process group created by this test, including native
            # children of npm launchers. Never contact a shared OpenCode service.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=10)
            except ProcessLookupError:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)


def install(env):
    subprocess.run(
        ["bash", str(REPO / "tmux-assistant-resurrect.tmux")],
        env=env,
        check=True,
        capture_output=True,
        timeout=20,
    )


def run(v1, v2, root):
    fake = root / "bin"
    fake.mkdir()
    tmux = fake / "tmux"
    tmux.write_text(
        '#!/bin/sh\ncase "$*" in\n'
        '  *show-option*assistant-resurrect-capture-env) printf TEST_CAPTURE_VAR ;;\n'
        "esac\nexit 0\n"
    )
    tmux.chmod(0o755)

    def environment(home, binary):
        home.mkdir()
        return {
            "HOME": str(home),
            "PATH": f"{fake}:{binary.parent}:{os.environ['PATH']}",
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local/share"),
            "XDG_STATE_HOME": str(home / ".local/state"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "TMPDIR": str(root),
            "TMUX_ASSISTANT_RESURRECT_DIR": str(home / "assistant-state"),
            "TMUX_PANE": "%contract-test",
            "TEST_CAPTURE_VAR": "contract value",
            "OPENCODE_SERVER_PASSWORD": "isolated-contract-test",
        }

    home = root / "v1"
    env = environment(home, v1)
    version = subprocess.check_output([str(v1), "--version"], env=env, text=True, timeout=20).strip()
    assert version.startswith(("1.", "v1.", "opencode v1.")), version
    install(env)
    plugin = home / ".config/opencode/plugins/session-tracker.js"
    assert plugin.is_symlink(), "V1 tracker was not installed"
    state = Path(env["TMUX_ASSISTANT_RESURRECT_DIR"])

    def read_state():
        files = list(state.glob("opencode-*.json"))
        return json.loads(files[0].read_text()) if len(files) == 1 else None

    with server(v1, home, env) as request:
        wait_for(lambda: request("/session"), lambda value: isinstance(value, list), "V1 ready")
        # Real session.created events from upstream, including two sessions in
        # one directory. No fabricated state artifact and no model/API call.
        for title in ("contract first", "contract second"):
            info = request("/session", "POST", {"title": title})
            data = wait_for(
                read_state,
                lambda value: value is not None and value["session_id"] == info["id"],
                "V1 native session.created tracking",
            )
            assert data["session"]["id"] == info["id"]
            assert data["env"]["TEST_CAPTURE_VAR"] == "contract value"
            assert data["env"]["tmux_pane"] == "%contract-test"
            assert (state / f"opencode-{data['pid']}.json").stat().st_mode & 0o777 == 0o600
        request(f"/session/{info['id']}", "PATCH", {"title": "contract updated"})
        wait_for(
            read_state,
            lambda value: value is not None and value["session"].get("title") == "contract updated",
            "V1 native session.updated tracking",
        )
    wait_for(lambda: list(state.glob("*.json")), lambda files: not files, "V1 exit cleanup")
    print(f"PASS: {version} native plugin loads, tracks created/updated sessions, captures env, cleans up")

    home = root / "v2"
    env = environment(home, v2)
    version = subprocess.check_output([str(v2), "--version"], env=env, text=True, timeout=20).strip()
    assert version.startswith(("2.", "v2.", "opencode v2.")), version
    plugin = home / ".config/opencode/plugins/session-tracker.js"
    plugin.parent.mkdir(parents=True)
    plugin.symlink_to(REPO / "hooks/opencode-session-track.js")
    with server(v2, home, env) as request:
        inventory = wait_for(
            lambda: request("/api/plugin")["data"],
            lambda items: any(item.get("state", {}).get("error") == ERROR for item in items),
            "V2 rejects V1 plugin with the reported error",
        )
        assert any(item.get("source", {}).get("path", "").endswith("session-tracker.js") for item in inventory)
    print(f"PASS: {version} reproduces issue #107 with the native V1 plugin")

    install(env)
    install(env)
    assert not plugin.is_symlink() and not plugin.exists(), "V2 must not reinstall the V1 tracker"
    assert "claude-session-track" in (home / ".claude/settings.json").read_text()
    with server(v2, home, env) as request:
        inventory = wait_for(
            lambda: request("/api/plugin")["data"], lambda items: bool(items), "V2 inventory ready"
        )
        assert not any(item.get("state", {}).get("status") == "failed" for item in inventory)
        assert not any(item.get("source", {}).get("path", "").endswith("session-tracker.js") for item in inventory)
    print(f"PASS: {version} starts without the incompatible tracker after repeated installs; Claude remains installed")

    # V2 also provides opencode2, while V1 can win the opencode name on PATH.
    # Both use the same global config; probing only opencode misses this case.
    assert (v2.parent / "opencode2").exists(), "Expected the official V2 alternate executable"
    env["PATH"] = f"{fake}:{v1.parent}:{v2.parent}:{os.environ['PATH']}"
    plugin.symlink_to(REPO / "hooks/opencode-session-track.js")
    install(env)
    assert not plugin.is_symlink() and not plugin.exists(), "Mixed V1/V2 must not install a shared V1 tracker"
    print("PASS: mixed V1 opencode / V2 opencode2 installation removes the incompatible shared tracker")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    # Keep the .bin directory in PATH for the installer's version probe. Do not
    # resolve the symlink to the npm package's differently named launcher.
    binaries = [Path(arg).absolute() for arg in sys.argv[1:]]
    with tempfile.TemporaryDirectory(prefix="opencode-plugin-contract-") as temp:
        run(*binaries, Path(temp).resolve())
