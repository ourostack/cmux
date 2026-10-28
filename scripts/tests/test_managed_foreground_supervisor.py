"""Actual private foreground supervisor; no provider, model, app or terminal."""

import argparse
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import time
import unittest
import uuid

import test_managed_process_bootstrap as bootstrap


ROLE = "__managed-foreground-command-supervisor"


class ManagedForegroundSupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bootstrap.ManagedProcessBootstrapTests.setUpClass()
        cls.executable = bootstrap.ManagedProcessBootstrapTests.executable

    finish = staticmethod(bootstrap.ManagedProcessBootstrapTests.finish)
    live = bootstrap.ManagedProcessBootstrapTests.live

    def launch(self, command=None, stdin=subprocess.PIPE):
        nonce = uuid.uuid4()
        process = subprocess.Popen(
            [str(self.executable), ROLE, str(nonce),
             *(command or [str(self.executable), "--fixture-child"])],
            stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, process)
        frame = bootstrap.read_exact(process.stderr, 72)
        magic, actual_nonce, *values = struct.unpack(">8s16sIQIIQIIQI", frame)
        self.assertEqual(magic, b"CMXMSB01")
        self.assertEqual(actual_nonce, nonce.bytes)
        records = [tuple(values[i:i + 3]) for i in (0, 3, 6)]
        self.assertEqual(records[0][0], os.getpid())
        self.assertEqual(records[1][0], process.pid)
        for record in records:
            self.assertTrue(self.live(record), record)
        self.assertFalse(select.select([process.stdout, process.stderr], [], [], 0.05)[0],
                         "child ran before ready admission")
        return process, nonce, records

    def ready(self, process, nonce):
        process.stdin.write(b"CMXGO001" + nonce.bytes)
        process.stdin.close()

    def assert_never_resumed(self, process):
        output, error = process.communicate(timeout=7)
        self.assertEqual(output, b"")
        self.assertNotIn(b"child-started", error)
        self.assertNotEqual(process.returncode, 0)

    def test_fast_child_waits_for_exact_ready_and_eof_then_has_null_stdin(self):
        process, nonce, _ = self.launch([
            "/bin/sh", "-c",
            'test -c /dev/fd/0 && test "$(stat -f %r /dev/fd/0)" = '
            '"$(stat -f %r /dev/null)" && '
            'if read -r unexpected; then exit 19; fi; printf fast',
        ])
        process.stdin.write(b"CMXGO001" + nonce.bytes)
        process.stdin.flush()
        self.assertFalse(select.select([process.stdout], [], [], 0.1)[0],
                         "24 bytes without EOF authorized execution")
        process.stdin.close()
        process.stdin = None
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output, b"fast")
        self.assertEqual(error, b"")

    def test_invalid_frames_and_missing_bytes_never_resume_the_child(self):
        for kind in ("empty", "short", "magic", "nonce", "extra"):
            with self.subTest(kind=kind):
                process, nonce, _ = self.launch()
                frame = b"CMXGO001" + nonce.bytes
                frame = {
                    "empty": b"", "short": frame[:-1], "magic": b"X" + frame[1:],
                    "nonce": b"CMXGO001" + uuid.uuid4().bytes, "extra": frame + b"x",
                }[kind]
                process.stdin.write(frame)
                process.stdin.close()
                process.stdin = None
                self.assert_never_resumed(process)

    def test_partial_ready_is_accumulated_but_never_executes_until_eof(self):
        process, nonce, _ = self.launch()
        frame = b"CMXGO001" + nonce.bytes
        for part in (frame[:1], frame[1:9], frame[9:]):
            process.stdin.write(part)
            process.stdin.flush()
            self.assertFalse(select.select([process.stdout], [], [], 0.05)[0])
        process.stdin.close()
        process.stdin = None
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output, b"resumed\n")
        self.assertEqual(error, b"child-started\n")

    def test_open_ready_pipe_expires_at_the_absolute_deadline(self):
        for kind in ("missing", "partial", "complete-without-eof"):
            with self.subTest(kind=kind):
                started = time.monotonic()
                process, nonce, _ = self.launch()
                if kind != "missing":
                    time.sleep(2)
                    frame = b"CMXGO001" + nonce.bytes
                    process.stdin.write(frame[:1] if kind == "partial" else frame)
                    process.stdin.flush()
                self.assertNotEqual(process.wait(timeout=6), 0)
                self.assertLess(time.monotonic() - started, 6.5)
                process.stdin.close()
                process.stdin = None
                self.assert_never_resumed(process)

    def test_regular_file_is_not_a_ready_channel_even_with_valid_bytes(self):
        nonce = uuid.uuid4()
        path = bootstrap.ManagedProcessBootstrapTests.build / "not-a-control-pipe"
        path.write_bytes(b"CMXGO001" + nonce.bytes)
        with path.open("rb") as control:
            process = subprocess.Popen(
                [str(self.executable), ROLE, str(nonce), str(self.executable), "--fixture-child"],
                stdin=control, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        self.addCleanup(self.finish, process)
        receipt = bootstrap.read_exact(process.stderr, 72)
        self.assertEqual(receipt[:8], b"CMXMSB01")
        self.assert_never_resumed(process)

    def test_signals_before_ready_never_resume_the_child(self):
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signum=signum):
                process, _, _ = self.launch()
                process.send_signal(signum)
                self.assert_never_resumed(process)

    def test_in_group_survivor_with_closed_stdio_is_held_and_cleaned_up(self):
        process, nonce, _ = self.launch([
            "/bin/sh", "-c",
            'sleep 30 </dev/null >/dev/null 2>/dev/null & echo "$!"; sleep 0.1; exit 0',
        ])
        self.ready(process, nonce)
        process.stdin = None
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 254, error)
        self.assertIn(b"foreground ownership", error)
        descendant = int(output.strip())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            check = subprocess.run(["/bin/ps", "-p", str(descendant), "-o", "stat="],
                                   capture_output=True, text=True, timeout=2)
            if not check.stdout.strip() or check.stdout.strip().startswith("Z"):
                break
            time.sleep(0.01)
        else:
            self.fail("owned in-group descendant survived cleanup")

    def test_owner_or_signal_cleanup_cannot_turn_a_caught_signal_into_success(self):
        process, nonce, _ = self.launch([
            "/bin/sh", "-c", "trap 'exit 0' TERM; echo active; while :; do sleep 1; done",
        ])
        self.ready(process, nonce)
        process.stdin = None
        self.assertEqual(bootstrap.read_exact(process.stdout, 7), b"active\n")
        process.send_signal(signal.SIGTERM)
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 254, (output, error))
        self.assertIn(b"foreground ownership", error)

    def test_foreground_command_status_is_preserved_except_reserved_hold(self):
        for status in (0, 7, 254):
            with self.subTest(status=status):
                process, nonce, _ = self.launch(["/bin/sh", "-c", f"exit {status}"])
                self.ready(process, nonce)
                process.stdin = None
                output, error = process.communicate(timeout=5)
                self.assertEqual(process.returncode, status, error)
                self.assertEqual(output, b"")
                self.assertEqual(error, b"")

    def test_owner_death_before_ready_cleans_the_suspended_group(self):
        script = """
import os, subprocess, sys, time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
b = b''
while len(b) < 72:
    part = os.read(p.stderr.fileno(), 72 - len(b))
    if not part: sys.exit(2)
    b += part
os.write(1, b)
time.sleep(30)
"""
        owner = subprocess.Popen(
            [sys.executable, "-c", script, str(self.executable), ROLE, str(uuid.uuid4()),
             str(self.executable), "--fixture-child"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, owner)
        frame = bootstrap.read_exact(owner.stdout, 72)
        magic, _, *values = struct.unpack(">8s16sIQIIQIIQI", frame)
        self.assertEqual(magic, b"CMXMSB01")
        self.assertEqual(values[0], owner.pid)
        records = [tuple(values[i:i + 3]) for i in (3, 6)]
        owner.kill()
        owner.wait(timeout=3)
        deadline = time.monotonic() + 4
        while any(self.live(record) for record in records) and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertFalse(any(self.live(record) for record in records))

    def test_only_a_complete_generation_verified_solitary_group_can_finish(self):
        for scenario in (
            "leader", "unrelated", "missing", "pid", "group", "seconds", "microseconds",
            "incomplete", "unreadable", "truncated", "member", "zombie-member",
        ):
            with self.subTest(scenario=scenario):
                result = subprocess.run(
                    [str(self.executable), "--fixture-foreground-census", scenario],
                    capture_output=True, timeout=3,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"true" if scenario in ("leader", "unrelated") else b"false")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    bootstrap.MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
