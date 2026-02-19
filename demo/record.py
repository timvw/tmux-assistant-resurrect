#!/usr/bin/env python3
"""
tmux-assistant-resurrect demo recorder — drives shellwright MCP to create a GIF
showing the full save -> kill -> restore cycle.

Usage:
    # Start shellwright in HTTP mode first:
    npx -y @dwmkerr/shellwright --http --font-size 16 --cols 140 --rows 35

    # Then run this script:
    uv run --with "mcp[cli]" python demo/record.py

Environment variables:
    SHELLWRIGHT_URL  — shellwright endpoint (default: http://localhost:7498)
    SHELLWRIGHT_OUTPUT — output directory (default: ./demo/output)
    DEMO_HOST — SSH host alias for remote machine (default: aspire)
"""

import asyncio
import json
import os
import sys
import urllib.request

SHELLWRIGHT_URL = os.environ.get("SHELLWRIGHT_URL", "http://localhost:7498")
OUTPUT_DIR = os.environ.get("SHELLWRIGHT_OUTPUT", "./demo/output")
DEMO_HOST = os.environ.get("DEMO_HOST", "aspire")

# ANSI colors for logging
CYAN = "\033[36m"
GREEN = "\033[32m"
DIM = "\033[2m"
RESET = "\033[0m"

# tmux prefix on aspire is Ctrl+a. Sending prefix keys via shellwright
# is unreliable (timing issues with the terminal emulator). Instead,
# drive save/restore from outside tmux using tmux run-shell.
RESURRECT_SAVE = "~/.tmux/plugins/tmux-resurrect/scripts/save.sh"
RESURRECT_RESTORE = "~/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
CTRL_A = "\x01"
ENTER = "\r"


async def call_tool(session, name: str, args: dict) -> dict:
    """Call a shellwright MCP tool and return parsed JSON response."""
    print(
        f"  {CYAN}{name}{RESET}({', '.join(f'{k}={v!r}' for k, v in args.items() if k != 'session_id')})"
    )
    result = await session.call_tool(name, args)
    text = ""
    if result.content:
        for content in result.content:
            if hasattr(content, "text"):
                text += content.text
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return {"raw": text}


async def download(data: dict, output_dir: str):
    """Download file if response contains download_url."""
    if "download_url" in data and "filename" in data:
        path = os.path.join(output_dir, data["filename"])
        urllib.request.urlretrieve(data["download_url"], path)
        print(f"  {GREEN}saved:{RESET} {path}")


async def wait(seconds: float):
    """Wait with a message."""
    print(f"  {DIM}waiting {seconds}s...{RESET}")
    await asyncio.sleep(seconds)


async def start_shell(session) -> tuple[str, dict]:
    """Start a new shellwright shell session with sanitized prompt."""
    shell = await call_tool(
        session,
        "shell_start",
        {
            "command": "bash",
            "args": ["--login", "-i"],
            "cols": 140,
            "rows": 35,
            "theme": "one-dark",
        },
    )
    sid = shell["shell_session_id"]
    # Sanitize the LOCAL prompt to avoid leaking hostname/username
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "export PS1='$ '\r", "delay_ms": 500},
    )
    return sid, shell


async def setup_ssh(session, sid: str):
    """SSH to remote host and sanitize prompt. Done BEFORE recording starts."""
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": f"ssh {DEMO_HOST}\r", "delay_ms": 3000},
    )
    # Sanitize prompt on remote
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "export PS1='$ '\r", "delay_ms": 500},
    )
    # Clear screen so recording starts clean
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "clear\r", "delay_ms": 500},
    )


async def demo_save_restore(session, output_dir: str):
    """Record the full save -> kill -> restore cycle.

    All tmux interactions are driven from OUTSIDE tmux using
    `tmux run-shell` and `tmux attach`. This avoids prefix-key
    timing issues with the shellwright terminal emulator.
    """
    print(f"\n{'=' * 60}")
    print("Recording: save -> kill -> restore cycle")
    print(f"{'=' * 60}\n")

    sid, _ = await start_shell(session)

    # SSH and sanitize (not recorded)
    await setup_ssh(session, sid)

    # --- Start recording ---
    await call_tool(session, "shell_record_start", {"session_id": sid, "fps": 8})

    # Step 1: Show running sessions and active panes/windows
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux list-sessions\r", "delay_ms": 1500},
    )
    await wait(1.5)
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux list-windows -a\r", "delay_ms": 1000},
    )
    await wait(1)
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} active=#{pane_active} cmd=#{pane_current_command}'\r",
            "delay_ms": 1000,
        },
    )
    await wait(1.5)

    # Step 2: Save — trigger tmux-resurrect save from outside tmux.
    # This runs save.sh which saves layout + triggers the post-save hook
    # that detects assistants and writes session IDs.
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": f"tmux run-shell {RESURRECT_SAVE}\r",
            "delay_ms": 500,
        },
    )
    await wait(6)

    # Step 3: Show saved assistant sessions JSON
    jq_filter = """'[ .sessions[] | {pane, tool, session_id} ]'"""
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": f"cat ~/.tmux/resurrect/assistant-sessions.json | jq {jq_filter}\r",
            "delay_ms": 500,
        },
    )
    await wait(3)

    # Verification screenshot: saved JSON
    data = await call_tool(
        session,
        "shell_screenshot",
        {"session_id": sid, "name": "verify-saved-json"},
    )
    await download(data, output_dir)

    # Step 4: Kill tmux server — destroys all sessions and agents
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux kill-server\r", "delay_ms": 1500},
    )
    await wait(1.5)

    # Step 5: Show sessions are gone
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux list-sessions\r", "delay_ms": 1500},
    )
    await wait(2)

    # Step 6: Start fresh tmux server (detached — we stay in our shell).
    # Disable continuum auto-restore so we can trigger restore manually.
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux new-session -d -s main\r",
            "delay_ms": 2000,
        },
    )
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux set-option -g @continuum-restore 'off'\r",
            "delay_ms": 500,
        },
    )
    await wait(0.5)

    # Step 7: Trigger restore from outside — recreates all saved sessions
    # and sends resume commands to agent panes.
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": f"tmux run-shell {RESURRECT_RESTORE}\r",
            "delay_ms": 500,
        },
    )
    # Wait for tmux-resurrect to restore sessions + assistant-resurrect
    # to send resume commands + agents to actually start.
    await wait(15)

    # Step 8: Remove bootstrap session
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux kill-session -t main 2>/dev/null\r",
            "delay_ms": 500,
        },
    )
    await wait(0.5)

    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "clear\r", "delay_ms": 500},
    )
    await wait(0.5)

    # Step 9: Show sessions are restored and active panes/windows
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux list-sessions\r", "delay_ms": 1500},
    )
    await wait(2)
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "tmux list-windows -a\r", "delay_ms": 1000},
    )
    await wait(1)
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} active=#{pane_active} cmd=#{pane_current_command}'\r",
            "delay_ms": 1000,
        },
    )
    await wait(1.5)

    # Step 9: Show restore log — proves which assistants were resumed
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tail -4 ~/.tmux/resurrect/assistant-restore.log\r",
            "delay_ms": 1500,
        },
    )
    await wait(2)

    # Verification screenshot: restored sessions + log
    data = await call_tool(
        session,
        "shell_screenshot",
        {"session_id": sid, "name": "verify-restored-sessions"},
    )
    await download(data, output_dir)

    # Step 10: Attach to skynet to show OpenCode TUI with restored session.
    # Unset TMUX in case it leaked from a prior attach (prevents nesting error).
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "unset TMUX; tmux attach -t skynet\r",
            "delay_ms": 3000,
        },
    )
    # Wait for OpenCode TUI to render with restored conversation
    await wait(8)

    # Verification screenshot: agent TUI after restore
    data = await call_tool(
        session,
        "shell_screenshot",
        {"session_id": sid, "name": "verify-agent-tui"},
    )
    await download(data, output_dir)

    # Stop recording (while showing the restored agent TUI)
    data = await call_tool(
        session,
        "shell_record_stop",
        {"session_id": sid, "name": "demo-save-restore"},
    )
    await download(data, output_dir)

    # Cleanup: detach from tmux, re-enable continuum-restore, exit SSH
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": f"{CTRL_A}d", "delay_ms": 1000},
    )
    # If detach didn't work (prefix issue), just kill the shell
    await call_tool(
        session,
        "shell_send",
        {
            "session_id": sid,
            "input": "tmux set-option -g @continuum-restore 'on' 2>/dev/null\r",
            "delay_ms": 500,
        },
    )
    await call_tool(
        session,
        "shell_send",
        {"session_id": sid, "input": "exit\r", "delay_ms": 500},
    )
    await call_tool(session, "shell_stop", {"session_id": sid})


async def main():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print(f"{DIM}shellwright:{RESET} {SHELLWRIGHT_URL}")
    print(f"{DIM}output:{RESET} {OUTPUT_DIR}")
    print(f"{DIM}host:{RESET} {DEMO_HOST}")

    try:
        async with streamablehttp_client(f"{SHELLWRIGHT_URL}/mcp") as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                print(f"{GREEN}Connected to shellwright{RESET}")

                await demo_save_restore(session, OUTPUT_DIR)

        print(f"\n{GREEN}Demo recorded. Output in {OUTPUT_DIR}/{RESET}")

    except Exception as e:
        if "Connect" in type(e).__name__ or "connection" in str(e).lower():
            print(
                f"\nError: Cannot connect to shellwright at {SHELLWRIGHT_URL}\n"
                f"Start it first: npx -y @dwmkerr/shellwright --http --font-size 16 --cols 140 --rows 35",
                file=sys.stderr,
            )
        else:
            raise
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
