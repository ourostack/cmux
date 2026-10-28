#!/usr/bin/env python3
"""Exercise readiness CLI compatibility without a native app or qualified agent."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import HookSocketServer


class ShepherdHookReadinessTests(unittest.TestCase):
    def setUp(self):
        configured = os.environ.get("CMUX_CLI_BIN")
        self.assertIsNotNone(configured, "Pin the exact test binary with CMUX_CLI_BIN")
        self.cli = str(Path(configured).resolve())
        self.assertTrue(os.access(self.cli, os.X_OK))
        self.temp = tempfile.TemporaryDirectory(prefix="shepherd-readiness-cli-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace, self.surface = str(uuid.uuid4()), str(uuid.uuid4())
        self.server = HookSocketServer(self.workspace, self.surface)
        self.server.__enter__()
        self.addCleanup(self.server.__exit__, None, None, None)
        self.state = self.root / "state.json"
        self.state.write_text("unchanged unqualified state sentinel")
        Path(str(self.state) + ".lock").mkdir()
        self.env = cli_environment(
            self.server.socket_path, home=self.root,
            CMUX_WORKSPACE_ID=self.workspace, CMUX_SURFACE_ID=self.surface,
            CMUX_CLAUDE_HOOK_STATE_PATH=str(self.state),
            CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
            CMUX_SHEPHERD_QUALIFIED_AGENTS="claude",
            CMUX_SHEPHERD_QUALIFIED_BINARIES='{"2.1.295":["spoofed"]}',
        )

    def run_cli(self, *args, payload=None):
        return subprocess.run(
            [self.cli, "--socket", self.server.socket_path, "hooks", "claude", *args],
            input=json.dumps(payload or {}), env=self.env, capture_output=True, text=True,
            timeout=8,
        )

    def test_inject_settings_advertises_codec_not_qualification(self):
        result = self.run_cli("inject-settings")
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(result.stdout)
        self.assertEqual(settings.get("__cmux", {}).get("shepherdReadiness"), 2)
        commands = [
            hook["command"] for groups in settings["hooks"].values()
            for group in groups for hook in group["hooks"]
        ]
        self.assertFalse(any("readiness-event" in command for command in commands))
        self.assertEqual(self.server.commands, [])

    def test_unqualified_launch_does_not_touch_store_execute_or_contact_app(self):
        executable = self.root / "claude"
        executable.write_text("#!/bin/sh\nprintf ran > \"$0.ran\"\nprintf '2.1.295 (Claude Code)\\n'\n")
        executable.chmod(0o700)
        settings = self.root / "existing-settings.json"
        settings.write_text('{"effortLevel":"high"}')
        result = self.run_cli(
            "prepare-readiness", "--executable", str(executable),
            "--settings", str(settings), "--root-pid", str(os.getpid()),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(settings))
        self.assertEqual(settings.read_text(), '{"effortLevel":"high"}')
        self.assertEqual(self.state.read_text(), "unchanged unqualified state sentinel")
        self.assertFalse(Path(str(executable) + ".ran").exists())
        self.assertEqual(self.server.commands, [])

    def test_unregistered_work_cannot_acknowledge_a_durable_invalidation(self):
        for event in ("UserPromptSubmit", "PreToolUse"):
            with self.subTest(event=event):
                result = self.run_cli(
                    "readiness-event", event, "--launch", str(uuid.uuid4()),
                    payload={"session_id": str(uuid.uuid4()), "prompt_id": str(uuid.uuid4()),
                             "hook_event_name": event},
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotEqual(result.stdout.strip(), "{}")
                self.assertEqual(self.state.read_text(), "unchanged unqualified state sentinel")
        self.assertEqual(self.server.commands, [])


if __name__ == "__main__":
    unittest.main()
