#!/usr/bin/env python3
"""Exercise real Claude model switching and plugin save/restore against a local API.

No API credentials or live requests: every assistant response is served on loopback.
The real CLI still selects the request model and writes/reads its own transcript.
"""

import http.server
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import subprocess
import tempfile
import threading
import uuid

requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[],"has_more":false}')

    def do_POST(self):
        body = json.loads(
            self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}"
        )
        if "count_tokens" in self.path:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"input_tokens":10}')
            return
        model = body.get("model", "")
        requests.append({"path": self.path, "model": model})
        response = {
            "id": "msg_review",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [{"type": "text", "text": "OK"}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 1},
        }
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/event-stream" if body.get("stream") else "application/json",
        )
        self.end_headers()
        if not body.get("stream"):
            self.wfile.write(json.dumps(response).encode())
            return
        events = [
            (
                "message_start",
                {
                    "type": "message_start",
                    "message": dict(response, content=[], stop_reason=None),
                },
            ),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": "OK"},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            (
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 1},
                },
            ),
            ("message_stop", {"type": "message_stop"}),
        ]
        for name, event in events:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(event)}\n\n".encode())


def main():
    binary = shutil.which(os.environ.get("CLAUDE_BINARY", "claude"))
    if not binary:
        print("[skip] Claude replay contract: Claude CLI unavailable")
        return
    repo = Path(__file__).resolve().parent.parent
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="claude-replay-") as sandbox:
        root = Path(sandbox)
        config = root / "config"
        bindir = root / "bin"
        bindir.mkdir()
        (bindir / "claude").symlink_to(binary)
        env = {
            k: os.environ[k]
            for k in ("PATH", "HOME", "TMPDIR", "SHELL")
            if k in os.environ
        }
        env.update(
            CLAUDE_CONFIG_DIR=str(config),
            ANTHROPIC_API_KEY="local-contract-test-only",
            ANTHROPIC_BASE_URL=f"http://127.0.0.1:{server.server_port}",
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
            DISABLE_AUTOUPDATER="1",
            ANTHROPIC_MODEL="opus",
        )
        sid = str(uuid.uuid4())
        base = [binary, "-p", "--permission-mode", "dontAsk", "--tools", ""]
        # safe-mode was added after some supported CLI versions. Isolated
        # CLAUDE_CONFIG_DIR plus the fake API key also isolate older binaries.
        help_text = subprocess.check_output([binary, "--help"], env=env, text=True)
        if "--safe-mode" in help_text:
            base.append("--safe-mode")
        child = subprocess.Popen(
            base
            + [
                "--session-id",
                sid,
                "--model",
                "opus",
                "--verbose",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
            ],
            cwd=root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        events = queue.Queue()

        def read_events():
            for line in child.stdout:
                try:
                    events.put(json.loads(line))
                except ValueError:
                    pass

        threading.Thread(target=read_events, daemon=True).start()

        def turn(text):
            before = len(requests)
            child.stdin.write(
                json.dumps(
                    {
                        "type": "user",
                        "session_id": sid,
                        "message": {"role": "user", "content": text},
                        "parent_tool_use_id": None,
                    }
                )
                + "\n"
            )
            child.stdin.flush()
            while True:
                event = events.get(timeout=45)
                if event.get("type") == "result":
                    assert not event.get("is_error"), event
                    return requests[before:]

        try:
            initial = turn("Reply OK")[-1]["model"]
            turn("/model sonnet")
            switched = turn("Reply OK again")[-1]["model"]
            assert initial != switched, (initial, switched)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        print(f"[pass] real Claude switches in-session: {initial} -> {switched}")
        transcripts = {p: p.read_bytes() for p in config.rglob("*.jsonl")}
        assert transcripts, "Claude did not persist a resumable transcript"

        # tmux only supplies options and records the command. After restore,
        # execute that exact command with print-mode arguments appended so the
        # real CLI performs a deterministic single turn without a terminal.
        (bindir / "tmux").write_text("""#!/usr/bin/env bash
case "$1" in
show-option)
  case "$3" in
  @assistant-resurrect-capture-env) echo ANTHROPIC_MODEL ;;
  @assistant-resurrect-drop-flags) echo "${REPLAY_TEST_DROP_FLAGS:-}" ;;
  @assistant-resurrect-drop-env) echo "${REPLAY_TEST_DROP_ENV:-}" ;;
  esac ;;
list-panes) echo '%1|0|0|contract' ;;
list-clients) echo client ;;
display-message)
  case "$5" in
  '#{pane_current_command}') echo bash ;;
  '#{pane_pid}') echo 99999999 ;;
  esac ;;
send-keys) [ "$4" = clear ] || printf '%s\\n' "$4" >"$REPLAY_TEST_COMMAND" ;;
clear-history) : ;;
*) exit 1 ;;
esac
""")
        (bindir / "sleep").write_text("#!/usr/bin/env bash\nexit 0\n")
        (bindir / "tmux").chmod(0o755)
        (bindir / "sleep").chmod(0o755)
        state = root / "state"
        resurrect = root / "resurrect"
        state.mkdir()
        resurrect.mkdir()
        (state / "claude-99999999.json").write_text(
            json.dumps(
                {
                    "session_id": sid,
                    "model": "opus",
                    "env": {"ANTHROPIC_MODEL": "opus"},
                }
            )
        )
        env.update(
            PATH=str(bindir) + os.pathsep + env["PATH"],
            TMUX_ASSISTANT_RESURRECT_DIR=str(state),
            TMUX_RESURRECT_DIR=str(resurrect),
            REPLAY_TEST_COMMAND=str(root / "command"),
            REPLAY_TEST_REPO=str(repo),
            REPLAY_TEST_CWD=str(root),
        )
        save = """source "$REPLAY_TEST_REPO/scripts/save-assistant-sessions.sh"
PARTS_FILE="$REPLAY_TEST_CWD/parts.json"
: >"$PARTS_FILE"
emit_session contract:0.0 claude 99999999 'claude --model opus --settings={"theme":"dark"}' "$REPLAY_TEST_CWD"
jq -s '{sessions:.}' "$PARTS_FILE" >"$TMUX_RESURRECT_DIR/assistant-sessions.json"
"""
        for name, drop_flags, drop_env, expected in [
            ("unchanged", "", "", initial),
            ("flags only", "--model --settings", "", initial),
            ("environment only", "", "ANTHROPIC_MODEL", initial),
            ("both opt-outs", "--model --settings", "ANTHROPIC_MODEL", switched),
        ]:
            for path, content in transcripts.items():
                path.write_bytes(content)
            case_env = env | {
                "REPLAY_TEST_DROP_FLAGS": drop_flags,
                "REPLAY_TEST_DROP_ENV": drop_env,
            }
            subprocess.run(
                [os.environ.get("TEST_BASH", "bash"), "-c", save],
                cwd=root,
                env=case_env,
                check=True,
                capture_output=True,
                timeout=45,
            )
            subprocess.run(
                [
                    os.environ.get("TEST_BASH", "bash"),
                    str(repo / "scripts/restore-assistant-sessions.sh"),
                ],
                cwd=root,
                env=case_env,
                check=True,
                capture_output=True,
                timeout=45,
            )
            command = (root / "command").read_text().strip()
            extra = [
                "-p",
                "--permission-mode",
                "dontAsk",
                "--tools",
                "",
                "--output-format",
                "json",
                "Reply OK",
            ]
            if "--safe-mode" in help_text:
                extra.insert(1, "--safe-mode")
            before = len(requests)
            completed = subprocess.run(
                ["bash", "-c", command + " " + shlex.join(extra)],
                cwd=root,
                env=case_env,
                capture_output=True,
                text=True,
                timeout=45,
            )
            assert completed.returncode == 0, (name, completed.stdout, completed.stderr)
            observed = requests[before:][-1]["model"]
            assert observed == expected, (name, expected, observed, command)
            print(f"[pass] save/restore with {name}: {observed}")
    server.shutdown()
    print("Claude replay contract: 5 passed, 0 failed")


if __name__ == "__main__":
    main()
