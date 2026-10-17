#!/usr/bin/env python3
"""Hermetic tests for the observed agy PID-log contract; no account required."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "agy_session", ROOT / "scripts/py/agy_session.py"
)
agy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agy)
A = "819ede29-d40e-41d8-8e91-e7cd0f8f7ea8"
B = "e8d5d5bb-d278-44cc-9ba3-79b6896dce97"


class Sessions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "cli-test.log"

    def write(self, text):
        self.path.write_text(text)
        return self.path

    def resolve(self, text, args="agy"):
        self.write(text)
        with patch.object(agy, "log_paths", return_value=[self.path]):
            return agy.resolve(123, args)

    def test_stream_selection(self):
        self.assertEqual(self.resolve(f"I manager.go] Streaming conversation {A}\n"), A)

    def test_switch_overrides_launch_id(self):
        self.assertEqual(
            self.resolve(
                f"Streaming conversation {A}\nStarting conversation update stream for {B}\n",
                f"agy --conversation {A}",
            ),
            B,
        )

    def test_picker_preview_does_not_switch(self):
        self.assertEqual(
            self.resolve(
                f"Streaming conversation {A}\nGetConversationDetail: found conversation {B} (active=false)\n"
            ),
            A,
        )

    def test_clear_does_not_restore_old_argv(self):
        self.assertEqual(
            self.resolve(
                f"Streaming conversation {A}\nFull redraw completed (RerenderAll) for conversation  (epoch 0, items 1)\n",
                f"agy --conversation {A}",
            ),
            "",
        )

    def test_redraw_of_current_conversation(self):
        self.assertEqual(
            self.resolve(
                f"Full redraw completed (RerenderAll) for conversation {B} (epoch 0, items 10)\n"
            ),
            B,
        )

    def test_argv_fallback(self):
        with patch.object(agy, "log_paths", return_value=[]):
            for args in [f"agy --conversation {A}", f"agy --conversation={A}"]:
                self.assertEqual(agy.resolve(123, args), A)
            self.assertEqual(agy.resolve(123, "agy --continue"), "")
            self.assertEqual(agy.resolve(123, "agy --conversation not-a-uuid"), "")

    def test_conflicting_logs_fail_closed(self):
        other = Path(self.temp.name) / "other.log"
        self.write(f"Streaming conversation {A}\n")
        other.write_text(f"Streaming conversation {B}\n")
        with patch.object(agy, "log_paths", return_value=[self.path, other]):
            self.assertEqual(agy.resolve(123, f"agy --conversation {A}"), "")

    def test_noninteractive_is_not_restored(self):
        self.assertEqual(
            self.resolve(
                f"Streaming conversation {A}\n", f"agy --conversation {A} --print hello"
            ),
            "",
        )

    def test_prompt_cannot_supply_a_session_selector(self):
        with patch.object(agy, "log_paths", return_value=[]):
            self.assertEqual(
                agy.resolve(
                    123, f"agy --prompt-interactive please use --conversation {A}"
                ),
                "",
            )

    def test_missing_log(self):
        self.assertEqual(agy.selected_session(self.path), (False, ""))

    def test_pid_specific_files_same_workspace(self):
        other = Path(self.temp.name) / "other.log"
        self.write(f"Streaming conversation {A}\n")
        other.write_text(f"Streaming conversation {B}\n")
        with patch.object(
            agy,
            "log_paths",
            side_effect=lambda pid, args: [self.path if pid == 101 else other],
        ):
            self.assertEqual(agy.resolve(101, "agy"), A)
            self.assertEqual(agy.resolve(102, "agy"), B)

    def test_lsof_custom_log_with_spaces(self):
        # lsof is a POSIX contract; keep fixture paths POSIX even on the
        # Windows portability canary, which never runs a real lsof process.
        path = "/tmp/Antigravity Work/my custom.log"
        result = type(
            "Result", (), {"stdout": b"p123\0\nf4\0n" + path.encode() + b"\0\n"}
        )()
        with (
            patch.object(agy.Path, "is_dir", return_value=False),
            patch.object(agy.Path, "is_file", return_value=True),
            patch.object(agy.subprocess, "run", return_value=result),
        ):
            self.assertEqual(agy.log_paths(123, "agy --log-file=" + path), [path])
            native = "/tmp/antigravity-cli/log/cli-test.log"
            result.stdout = b"p123\0\nf4\0n" + native.encode() + b"\0\n"
            self.assertEqual(agy.log_paths(123, "agy"), [native])

    def test_invalid_pid(self):
        for pid in [0, 1, -2, "not-a-pid"]:
            self.assertEqual(agy.log_paths(pid, "agy"), [])


if __name__ == "__main__":
    unittest.main()
