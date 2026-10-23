#!/usr/bin/env python3
"""Hermetic tests for the observed agy PID-log contract; no account required."""

import importlib.util
import os
import shutil
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

    def test_prompt_words_do_not_select_noninteractive_mode(self):
        for prompt in [
            "--prompt-interactive fix the -p handling",
            "-i explain --print",
        ]:
            self.assertEqual(
                self.resolve(f"Streaming conversation {A}\n", "agy " + prompt), A
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
            side_effect=lambda pid, args, cwd: [self.path if pid == 101 else other],
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
            # Windows pathlib does not consider /tmp/... an absolute path.
            patch.object(agy.Path, "is_absolute", return_value=False),
            patch.object(agy.subprocess, "run", return_value=result),
            patch.object(agy, "exact_argv", return_value=None),
        ):
            self.assertEqual(agy.log_paths(123, "agy --log-file=" + path), [path])
            native = "/tmp/antigravity-cli/log/cli-test.log"
            result.stdout = b"p123\0\nf4\0n" + native.encode() + b"\0\n"
            self.assertEqual(agy.log_paths(123, "agy"), [native])

    def test_lsof_skips_network_name_lookups(self):
        # Host and port lookups for a process's sockets can stall on slow
        # reverse DNS past the timeout; log discovery needs file paths only.
        result = type("Result", (), {"stdout": b""})()
        with (
            patch.object(agy.Path, "is_dir", return_value=False),
            patch.object(agy.subprocess, "run", return_value=result) as run,
            patch.object(agy, "exact_argv", return_value=None),
        ):
            agy.log_paths(123, "agy")
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], "lsof")
        self.assertIn("-n", argv)
        self.assertIn("-P", argv)

    def test_invalid_pid(self):
        for pid in [0, 1, -2, "not-a-pid"]:
            self.assertEqual(agy.log_paths(pid, "agy"), [])

    @unittest.skipUnless(
        Path("/proc/self/fd").is_dir() or shutil.which("lsof"), "needs /proc or lsof"
    )
    def test_real_open_relative_log_switch_and_clear(self):
        # Exercise the OS producer, not a fabricated log_paths result.
        self.write(f"Streaming conversation {B}\n")
        old_cwd = Path.cwd()
        self.addCleanup(os.chdir, old_cwd)
        os.chdir(self.temp.name)
        with self.path.open("a") as log:
            for spelling in [
                "cli-test.log",
                "./cli-test.log",
                str(self.path.resolve()),
            ]:
                args = f"agy --log-file {spelling} --conversation {A}"
                self.assertEqual(agy.resolve(os.getpid(), args), B)
            self.assertEqual(
                agy.resolve(
                    os.getpid(),
                    f"agy --log-file missing.log --log-file cli-test.log --conversation {A}",
                ),
                B,
            )
            log.write(
                "Full redraw completed (RerenderAll) for conversation  (epoch 0, items 1)\n"
            )
            log.flush()
            self.assertEqual(
                agy.resolve(
                    os.getpid(), f"agy --log-file cli-test.log --conversation {A}"
                ),
                "",
            )

    @unittest.skipUnless(os.name == "posix", "lsof uses POSIX paths")
    def test_lsof_cwd_normalizes_relative_log(self):
        path = self.write(f"Streaming conversation {B}\n").resolve()
        result = type(
            "Result",
            (),
            {
                "stdout": (
                    b"p123\0\nfcwd\0n"
                    + os.fsencode(path.parent)
                    + b"\0\nf4\0n"
                    + os.fsencode(path)
                    + b"\0\n"
                )
            },
        )()
        with (
            patch.object(agy.Path, "is_dir", return_value=False),
            patch.object(agy.subprocess, "run", return_value=result),
            patch.object(agy, "exact_argv", return_value=None),
        ):
            self.assertEqual(
                agy.resolve(123, f"agy --log-file ./cli-test.log --conversation {A}"), B
            )


class Replay(unittest.TestCase):
    value_flags = {
        "--log-file",
        "--conversation",
        "--model",
        "--effort",
        "--add-dir",
        "--mode",
    }

    def test_flattened_log_path_preserves_restrictions(self):
        for option in ["--log-file ", "--log-file="]:
            with patch.object(agy, "exact_argv", return_value=None):
                self.assertEqual(
                    agy.replay_args(
                        123,
                        "agy --dangerously-skip-permissions "
                        + option
                        + "/tmp/My Project/old.log --sandbox --model test",
                        self.value_flags,
                    ),
                    "--dangerously-skip-permissions --sandbox --model test",
                )

    def test_exact_values_never_become_options(self):
        words = [
            "--log-file",
            "/tmp/My --sandbox/log\n--dangerously-skip-permissions",
            "--add-dir",
            "/tmp/My Project",
            "--sandbox",
            "--mode",
            "plan",
            "--prompt-interactive",
            "explain -p\n--dangerously-skip-permissions",
        ]
        with patch.object(agy, "exact_argv", return_value=words):
            self.assertEqual(
                agy.replay_args(123, "ignored", self.value_flags),
                "--sandbox --mode plan",
            )

    def test_flattened_multiline_prompt_stays_out(self):
        with patch.object(agy, "exact_argv", return_value=None):
            self.assertEqual(
                agy.replay_args(
                    123,
                    "agy --sandbox -i explain\n--dangerously-skip-permissions",
                    self.value_flags,
                ),
                "--sandbox",
            )

    def test_exact_flag_shaped_value_is_not_a_permission(self):
        with patch.object(
            agy,
            "exact_argv",
            return_value=["--log-file", "--dangerously-skip-permissions", "--sandbox"],
        ):
            self.assertEqual(
                agy.replay_args(123, "ignored", self.value_flags), "--sandbox"
            )


class LifecycleOracle(unittest.TestCase):
    def test_argv_or_login_screen_cannot_prove_loaded_history(self):
        spec = importlib.util.spec_from_file_location(
            "lifecycle", ROOT / "test/agy-live-lifecycle.py"
        )
        lifecycle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lifecycle)
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "cli.log"
            log.write_text(f"Streaming conversation {A}\n")
            marker = "a distinctive old answer"
            self.assertFalse(lifecycle.observed_history([log], A, "Sign in", marker))
            self.assertFalse(lifecycle.observed_history([], A, marker, marker))
            log.write_text(
                f"Full redraw completed (RerenderAll) for conversation {A} (epoch 0, items 10)\n"
            )
            self.assertTrue(lifecycle.observed_history([log], A, marker, marker))
            self.assertFalse(lifecycle.observed_history([log], B, marker, marker))
            self.assertFalse(lifecycle.observed_history([log], A, "Sign in", marker))


if __name__ == "__main__":
    unittest.main()
