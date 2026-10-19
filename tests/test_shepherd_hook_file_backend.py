#!/usr/bin/env python3
"""Synthetic component proof, NOT agent qualification or native input delivery.

Pin CMUX_CLI_BIN to an isolated compile-time fixture build and
CMUX_SHEPHERD_NATIVE_FIXTURE to the separately compiled native_parent.c.
The fixture build must admit ONLY that synthetic executable's digest. The
production policy must be restored and rebuilt before committing or installing.
Neither this test nor the native parent changes production qualification.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import HookSocketServer


class ReadinessFixtureServer(HookSocketServer):
    def __init__(self, workspace, surface):
        super().__init__(workspace, surface)
        self.host = str(uuid.uuid4())
        self.pid = None
        self.input_revision = 0
        self.rejected = []
        self.enqueued = []

    def _response_for(self, line):
        request = json.loads(line)
        method = request.get("method")
        params = request.get("params", {})
        result = {}
        if method == "system.capabilities":
            result = {"shepherd_guarded_input": {
                "protocol_version": 1, "state": "qualified", "agents": ["claude"],
            }}
        elif method == "surface.shepherd.inspect" and params == {
            "workspace_id": self.workspace_id, "surface_id": self.surface_id,
        }:
            result = {"protocol_version": 1, "host_instance": self.host, "snapshot": {
                "workspace_id": self.workspace_id, "surface_id": self.surface_id,
                "surface_generation": 1, "input_revision": self.input_revision,
                "agent": "claude", "process_instance": f"{self.pid}:123456",
            }}
        elif method == "agent.resolve_delivery_target" and params == {"pid": self.pid}:
            result = {"source": "pid", "workspace_id": self.workspace_id,
                      "surface_id": self.surface_id}
        elif method == "agent.hook.enqueue" and params.get("agent") == "claude":
            self.enqueued.append(params)
        else:
            self.rejected.append(request)
            return json.dumps({"id": request.get("id"), "ok": False,
                               "error": {"code": "forbidden_fixture_rpc",
                                         "message": "Not in the closed metadata-only fixture whitelist"}})
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


@unittest.skipUnless(os.environ.get("CMUX_SHEPHERD_NATIVE_FIXTURE"),
                     "Requires an isolated compile-time synthetic fixture build, never production qualification")
class ShepherdHookFileBackendTests(unittest.TestCase):
    def setUp(self):
        self.cli = str(Path(os.environ["CMUX_CLI_BIN"]).resolve(strict=True))
        self.fixture = str(Path(os.environ["CMUX_SHEPHERD_NATIVE_FIXTURE"]).resolve(strict=True))
        home = Path.home().resolve()
        self.temp = tempfile.TemporaryDirectory(prefix=".sw-f-", dir=home)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.workspace, self.surface = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        self.server = ReadinessFixtureServer(self.workspace, self.surface)
        self.server.__enter__()
        self.addCleanup(self.server.__exit__, None, None, None)
        self.state = self.root / "state.json"
        self.stderr = (self.root / "driver-stderr.log").open("w+")
        self.addCleanup(self.stderr.close)
        self.driver = subprocess.Popen(
            [self.fixture, self.cli, self.server.socket_path],
            env=cli_environment(
                self.server.socket_path, home=self.root,
                CMUX_WORKSPACE_ID=self.workspace, CMUX_SURFACE_ID=self.surface,
                CMUX_CLAUDE_HOOK_STATE_PATH=str(self.state),
                CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
            ),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
        )
        self.addCleanup(self.close_driver)
        self.server.pid = self.driver.pid
        self.session, self.prompt = str(uuid.uuid4()), str(uuid.uuid4())
        code, output = self.run_native("inject-settings")
        self.assertEqual(code, 0, output)
        self.settings = self.root / "settings.json"
        self.settings.write_text(output)
        self.settings.chmod(0o600)

    def close_driver(self):
        self.driver.stdin.close()
        try:
            self.driver.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.driver.kill()
            self.driver.wait(timeout=3)
        self.driver.stdout.close()
        self.assertEqual(self.server.rejected, [], "Fixture attempted a non-whitelisted RPC")

    def run_native(self, *args, payload=None):
        self.driver.stdin.write(("\t".join(args) + "\n" + json.dumps(payload or {}) + "\n").encode())
        self.driver.stdin.flush()
        output = bytearray()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.driver.stdout], [], [], 0.1)
            if not ready:
                continue
            byte = os.read(self.driver.stdout.fileno(), 1)
            self.assertTrue(byte, "Native fixture exited before CLI response")
            output.extend(byte)
            if byte == b"\n":
                lines = output.decode().splitlines()
                if lines[-1].startswith("__SHEPHERD_STATUS__"):
                    return int(lines[-1].removeprefix("__SHEPHERD_STATUS__")), "\n".join(lines[:-1]).strip()
        self.fail("Native fixture CLI response exceeded its deadline")

    def prepare(self):
        code, artifact = self.run_native(
            "prepare-readiness", "--executable", self.fixture, "--settings", str(self.settings),
            "--root-pid", str(self.driver.pid),
        )
        self.assertEqual(code, 0, artifact)
        self.assertTrue(self.state.exists(), "Qualified synthetic launch never registered its real file store")
        state = json.loads(self.state.read_text())
        producer = next(record["shepherdProducer"] for record in state["sessions"].values()
                        if record.get("shepherdProducer"))
        self.launch = producer["launch"]["id"]
        self.assertNotEqual(artifact, str(self.settings))
        self.assertEqual(producer["launch"]["pid"], self.driver.pid)
        self.assertEqual(producer["launch"]["executablePath"], self.fixture)
        self.assertEqual(Path(artifact).stat().st_mode & 0o777, 0o600)
        return artifact

    def event(self, name, **extra):
        return self.run_native("readiness-event", name, "--launch", self.launch, payload={
            "hook_event_name": name, "session_id": self.session, "prompt_id": self.prompt, **extra,
        })

    def producer(self):
        return json.loads(self.state.read_text())["sessions"][self.session]["shepherdProducer"]

    def seal(self):
        self.prepare()
        self.assertEqual(self.event("UserPromptSubmit"), (0, "{}"))
        self.assertEqual(self.event("Stop", background_tasks=[], session_crons=[]), (0, "{}"))
        producer = self.producer()
        self.assertEqual(producer["proof"]["version"], 2)
        self.assertEqual(producer["proof"]["promptID"].lower(), self.prompt.lower())
        return producer

    def test_real_file_backend_reentry_revokes_without_duplicate_launch(self):
        before = self.seal()
        first = before["launch"]
        artifact = self.prepare()
        self.assertTrue(Path(artifact).exists())
        after = self.producer()
        self.assertEqual(after["launch"], first)
        self.assertNotEqual(after["workRevision"], before["workRevision"])
        self.assertIsNone(after.get("proof"))

    def test_real_lock_open_failure_blocks_before_telemetry_acknowledgement(self):
        before = self.seal()
        lock = Path(str(self.state) + ".lock")
        saved_lock = lock.with_suffix(".saved-lock")
        lock.rename(saved_lock)
        lock.mkdir(mode=0o700)
        enqueued = len(self.server.enqueued)
        code, output = self.event("PreToolUse")
        self.assertEqual(code, 2, output)
        self.assertNotEqual(output.strip(), "{}")
        self.assertEqual(self.producer(), before)
        self.assertEqual(len(self.server.enqueued), enqueued)

    def test_nonoriginal_parent_cannot_invalidate_or_acknowledge_work(self):
        before = self.seal()
        enqueued = len(self.server.enqueued)
        result = subprocess.run(
            [self.cli, "--socket", self.server.socket_path, "hooks", "claude",
             "readiness-event", "PreToolUse", "--launch", self.launch],
            env=cli_environment(
                self.server.socket_path, home=self.root,
                CMUX_CLAUDE_HOOK_STATE_PATH=str(self.state),
                CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
            ),
            input=json.dumps({"session_id": self.session, "prompt_id": self.prompt,
                              "hook_event_name": "PreToolUse"}),
            text=True, capture_output=True, timeout=8,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("exact live native root", result.stderr)
        self.assertNotEqual(result.stdout.strip(), "{}")
        self.assertEqual(self.producer(), before)
        self.assertEqual(len(self.server.enqueued), enqueued)

    def test_changed_native_epoch_cannot_be_sealed_by_old_stop(self):
        self.prepare()
        self.assertEqual(self.event("UserPromptSubmit"), (0, "{}"))
        self.server.input_revision += 1
        self.assertEqual(self.event("Stop", background_tasks=[], session_crons=[]), (0, "{}"))
        self.assertIsNone(self.producer().get("proof"))

    def test_corrupt_sibling_blocks_work_before_metadata_enqueue(self):
        self.seal()
        state = json.loads(self.state.read_text())
        state["sessions"]["broken-sibling"] = {"shepherdProducer": "not a producer"}
        self.state.write_text(json.dumps(state))
        enqueued = len(self.server.enqueued)
        code, output = self.event("PreToolUse")
        self.assertEqual(code, 2, output)
        self.assertNotEqual(output.strip(), "{}")
        self.assertEqual(len(self.server.enqueued), enqueued)


if __name__ == "__main__":
    unittest.main()
