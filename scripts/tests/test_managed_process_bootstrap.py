"""Exercise the actual native supervisor against controlled, non-provider children."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
MANAGED = "__managed-agent-process-supervisor"
MODULE_CACHE = None


def read_exact(stream, count, timeout=3):
    deadline = time.monotonic() + timeout
    result = b""
    while len(result) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise AssertionError(f"Only received {len(result)} of {count} bytes before the deadline")
        block = os.read(stream.fileno(), count - len(result))
        if not block:
            raise AssertionError(f"EOF after {len(result)} of {count} required bytes")
        result += block
    return result


class ManagedProcessBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-supervisor-source-"))
        print(f"Retained exact-source fixture build: {cls.build}", file=sys.stderr)
        foundation = ROOT / "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process"
        control = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd"
        flags = ["swiftc", "-swift-version", "6", "-gnone", "-module-cache-path",
                 str(MODULE_CACHE or cls.build / "cache")]
        commands = [
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxFoundation",
                     str(foundation / "AgentPIDProcessIdentity.swift"),
                     str(foundation / "DarwinProcessEnumerator.swift"),
                     str(foundation / "DarwinProcessInfoReader.swift"),
                     str(foundation / "DarwinProcessListing.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_process_listing.swift"),
                     "-o", str(cls.build / "libCmuxFoundation.dylib")],
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxControlSocket",
                     "-I", str(cls.build), "-L", str(cls.build), "-lCmuxFoundation",
                     str(control / "ShepherdHookExecutableIdentity.swift"),
                     str(control / "ShepherdManagedBackendLaunchReceipt.swift"),
                     str(control / "ShepherdManagedBootstrapReader.swift"),
                     str(control / "ShepherdManagedPipeWriter.swift"),
                     str(control / "ShepherdManagedRPCFramer.swift"),
                     str(control / "ShepherdManagedSessionIdentity.swift"),
                     str(control / "ShepherdManagedSessionState.swift"),
                     "-o", str(cls.build / "libCmuxControlSocket.dylib")],
            flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build),
                     "-lCmuxFoundation", "-lCmuxControlSocket", "-Xlinker", "-rpath",
                     "-Xlinker", str(cls.build),
                     str(ROOT / "CLI/CodexTeamsPOSIXSupport.swift"),
                     str(ROOT / "CLI/OwnedProcessSupervisor.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionOwnedProcessLauncher.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedSession.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedCommand.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedCopilotLaunch.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedNativeOwner.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedProviderAdapter.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedCommandService.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedRendererController.swift"),
                     str(ROOT / "Sources/Panels/AgentSessionManagedRendererReservation.swift"),
                     str(ROOT / "Sources/Panels/CopilotManagedSession.swift"),
                     str(ROOT / "Sources/Panels/CopilotManagedConfiguration.swift"),
                     str(ROOT / "Sources/Panels/CopilotManagedEventMetadata.swift"),
                     str(ROOT / "Sources/Panels/CopilotManagedTurnLedger.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_session_lifetime.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_command_service.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_copilot_startup.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_process_supervisor_main.swift"),
                     "-o", str(cls.build / "supervisor")],
        ]
        for command in commands:
            result = subprocess.run(command, cwd=cls.build, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "supervisor"

    def launch(self, nonce, *child_args, stderr=subprocess.PIPE):
        process = subprocess.Popen(
            [str(self.executable), MANAGED, str(nonce), str(self.executable),
             "--fixture-child", *child_args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
        )
        self.addCleanup(self.finish, process)
        return process

    @staticmethod
    def finish(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                stream.close()

    def live(self, record):
        return subprocess.run(
            [str(self.executable), "--fixture-live", *map(str, record)],
            capture_output=True, timeout=3,
        ).returncode == 0

    def test_native_receipt_precedes_child_output_and_later_forgery_is_only_output(self):
        nonce = uuid.uuid4()
        process = self.launch(nonce, "--echo-stderr")
        frame = read_exact(process.stderr, 72)
        magic, wire_nonce, *values = struct.unpack(">8s16sIQIIQIIQI", frame)
        self.assertEqual(magic, b"CMXMSB01")
        self.assertEqual(wire_nonce, nonce.bytes)
        owner, supervisor, backend = [tuple(values[i:i + 3]) for i in (0, 3, 6)]
        self.assertEqual(owner[0], os.getpid())
        self.assertEqual(supervisor[0], process.pid)
        self.assertNotEqual(backend[0], process.pid)
        for record in (owner, supervisor, backend):
            self.assertGreater(record[0], 0)
            self.assertGreater(record[1], 0)
            self.assertTrue(0 <= record[2] < 1_000_000)
            self.assertTrue(self.live(record))
        self.assertEqual(read_exact(process.stderr, 14), b"child-started\n")
        self.assertEqual(read_exact(process.stdout, 8), b"resumed\n")
        process.stdin.write(frame)
        process.stdin.flush()
        self.assertEqual(read_exact(process.stderr, 72), frame)
        process.stdin.close()
        self.assertEqual(process.wait(timeout=4), 0)

    def test_native_launcher_prepares_the_private_command_without_starting_any_process(self):
        nonce = uuid.uuid4()
        result = subprocess.run(
            [str(self.executable), "--fixture-prepare-managed", str(nonce),
             str(self.executable), "/tmp"],
            capture_output=True, timeout=3,
        )
        self.assertEqual(result.returncode, 0)
        prepared = json.loads(result.stdout)
        self.assertEqual(os.path.realpath(prepared.pop("directory")), "/private/tmp")
        self.assertEqual(prepared, {
            "executable": str(self.executable),
            "arguments": [MANAGED, str(nonce).upper(), str(self.executable),
                          "--fixture-child", "literal argument"],
            "environment": {"FIXTURE": "controlled"},
            "running": False,
        })

    def test_the_actual_launcher_supervisor_reader_and_kernel_binding_compose(self):
        process = subprocess.Popen(
            [str(self.executable), "--fixture-run-launcher"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, process)
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, error)
        binding = json.loads(output)
        self.assertEqual(binding["owner"], process.pid)
        self.assertNotEqual(binding["supervisor"], binding["backend"])
        self.assertNotEqual(binding["owner"], binding["supervisor"])
        self.assertGreater(binding["backend"], 1)

    def test_receipt_write_failure_never_resumes_the_suspended_child(self):
        read_end, write_end = os.pipe()
        os.close(read_end)
        try:
            process = self.launch(uuid.uuid4(), stderr=write_end)
        finally:
            os.close(write_end)
        output, _ = process.communicate(timeout=4)
        self.assertEqual(output, b"")
        self.assertEqual(process.returncode, 1)

    def test_a_full_bootstrap_pipe_fails_without_blocking_or_resuming_the_child(self):
        read_end, write_end = os.pipe()
        try:
            flags = fcntl.fcntl(write_end, fcntl.F_GETFL)
            fcntl.fcntl(write_end, fcntl.F_SETFL, flags | os.O_NONBLOCK)
            while True:
                try:
                    os.write(write_end, b"x" * 4096)
                except BlockingIOError:
                    break
            fcntl.fcntl(write_end, fcntl.F_SETFL, flags)
            process = self.launch(uuid.uuid4(), stderr=write_end)
            output, _ = process.communicate(timeout=4)
            self.assertEqual(output, b"")
            self.assertEqual(process.returncode, 1)
        finally:
            os.close(read_end)
            os.close(write_end)

    def test_invalid_nonce_never_starts_a_child(self):
        process = self.launch("not-a-nonce")
        output, error = process.communicate(timeout=4)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(output, b"")
        self.assertFalse(error.startswith(b"CMXMSB01"))

    def test_legacy_manual_supervisor_does_not_emit_managed_transport_metadata(self):
        process = subprocess.Popen(
            [str(self.executable), "__owned-process-supervisor",
             str(self.executable), "--fixture-child"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, process)
        output, error = process.communicate(timeout=4)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(output, b"resumed\n")
        self.assertEqual(error, b"child-started\n")

    def test_parent_exit_still_cleans_the_real_backend_group(self):
        script = """
import os, subprocess, sys, time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
b = b''
while len(b) < 72:
    part = os.read(p.stderr.fileno(), 72 - len(b))
    if not part:
        sys.exit(2)
    b += part
os.write(1, b)
time.sleep(30)
"""
        owner = subprocess.Popen(
            [sys.executable, "-c", script, str(self.executable), MANAGED, str(uuid.uuid4()),
             str(self.executable), "--fixture-child", "--hold"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.finish, owner)
        frame = read_exact(owner.stdout, 72)
        magic, _, *values = struct.unpack(">8s16sIQIIQIIQI", frame)
        self.assertEqual(magic, b"CMXMSB01")
        supervisor, backend = [tuple(values[i:i + 3]) for i in (3, 6)]
        self.assertEqual(values[0], owner.pid)
        try:
            self.assertTrue(self.live(backend))
            owner.kill()
            owner.wait(timeout=3)
            deadline = time.monotonic() + 4
            while self.live(backend) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(self.live(backend), "backend survived its native owner's exit")
            while self.live(supervisor) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(self.live(supervisor), "supervisor did not finish group cleanup")
        finally:
            for record in (backend, supervisor):
                if self.live(record):
                    os.kill(record[0], signal.SIGKILL)

    def lifetime(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-lifetime", scenario],
            capture_output=True, timeout=40,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def test_a_native_receipt_waits_for_the_actual_provider_handshake(self):
        result = self.lifetime("handshake")
        self.assertEqual(result["afterReceipt"], "awaitingProvider")
        self.assertFalse(result["identityBeforeHandshake"])
        self.assertTrue(result["accepted"])
        self.assertEqual(result["providerSessionID"], "actual-provider-session")
        self.assertEqual(result["backend"], result["receiptBackend"])

    def test_old_launch_callbacks_cannot_bind_a_replacement_native_session(self):
        result = self.lifetime("stale")
        self.assertFalse(result["acceptedOld"])
        self.assertEqual(result["afterOld"], "awaitingProvider")
        self.assertTrue(result["acceptedCurrent"])
        self.assertEqual(result["providerSessionID"], "current-session")

    def test_native_handshake_session_identity_is_immutable(self):
        result = self.lifetime("conflict")
        self.assertTrue(result["acceptedFirst"])
        self.assertFalse(result["acceptedConflict"])
        self.assertEqual(result["phase"], "held")
        self.assertFalse(result["identityAfterConflict"])

    def test_actual_backend_exit_invalidates_while_supervisor_remains_alive(self):
        result = self.lifetime("backend-exit")
        self.assertTrue(result["boundBeforeExit"])
        self.assertTrue(result["supervisorStillAlive"])
        self.assertEqual(result["phase"], "held")
        self.assertFalse(result["identityAfterExit"])
        self.assertFalse(result["drained"])

    def test_explicit_abandonment_never_counts_as_actual_stream_drain(self):
        result = self.lifetime("abandon")
        self.assertEqual(result["phase"], "held")
        self.assertFalse(result["acceptedLate"])
        self.assertFalse(result["drained"])

    def test_stdout_errno_and_real_eof_are_different_native_results(self):
        result = self.lifetime("read-results")
        self.assertEqual(result["beforeClose"], "waiting")
        self.assertEqual(result["afterWriterClose"], "endOfFile")
        self.assertEqual(result["afterReaderClose"], "closed")
        self.assertFalse(result["closedIsDrain"])
        self.assertEqual(result["readFailure"], "errno:9")
        self.assertTrue(result["stickyFailure"])

    def test_real_eof_drains_but_never_becomes_provider_completion(self):
        result = self.lifetime("drain")
        self.assertEqual(result["phase"], "held")
        self.assertTrue(result["drained"])
        self.assertFalse(result["identityAfterExit"])

    def test_abandoned_provider_handshake_expires_without_retry_or_binding(self):
        result = self.lifetime("timeout")
        self.assertEqual(result["before"], "awaitingProvider")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "providerHandshakeUnavailable")
        self.assertFalse(result["acceptedLate"])

    def test_missing_bootstrap_expires_without_drain_or_identity(self):
        result = self.lifetime("bootstrap-timeout")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "bootstrapUnavailable")
        self.assertFalse(result["drained"])
        self.assertFalse(result["identity"])

    def test_pre_bootstrap_provider_handshake_is_refused(self):
        result = self.lifetime("early-handshake")
        self.assertFalse(result["accepted"])
        self.assertEqual(result["phase"], "held")
        self.assertFalse(result["identity"])

    def test_malformed_provider_session_id_cannot_become_native_identity(self):
        result = self.lifetime("invalid-handshake")
        self.assertFalse(result["accepted"])
        self.assertEqual(result["phase"], "held")
        self.assertFalse(result["identity"])

    def test_backend_death_before_provider_init_reports_failed_handshake(self):
        result = self.lifetime("pre-handshake-exit")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "providerHandshakeUnavailable")
        self.assertFalse(result["acceptedLate"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
