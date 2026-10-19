#!/usr/bin/env python3
"""Verify the real wrapper's final-artifact readiness handoff, with no native app."""
import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

from test_claude_wrapper_hooks import generated_claude_hook_settings, parse_settings_arg, run_wrapper


@unittest.skipUnless(sys.platform == "darwin", "Native readiness is macOS-only")
class ShepherdClaudeWrapperReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shepherd-wrapper-readiness-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.args = self.root / "prepare-args"
        self.settings = self.root / "prepare-settings.json"
        self.pid = self.root / "real-pid"

    def setup(self, behavior, qualify=True):
        def prepare(root, env):
            home = root / "home"
            home.mkdir()
            env.update(
                HOME=str(home),
                FAKE_REAL_PID_LOG=str(self.pid),
                FAKE_SHEPHERD_PREPARE_LOG=str(self.args),
                FAKE_SHEPHERD_PREPARE_COPY_LOG=str(self.settings),
                FAKE_SHEPHERD_PREPARE_BEHAVIOR=behavior,
            )
            document = json.loads(env["FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"])
            if qualify and "__cmux" in document:
                executable = Path(env["FAKE_REAL_NODE_SCRIPT"]).with_name("claude")
                document["__cmux"]["shepherdQualifiedExecutables"] = [
                    hashlib.sha256(executable.read_bytes()).hexdigest()
                ]
                env["FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"] = json.dumps(
                    document, sort_keys=True, separators=(",", ":")
                )
        return prepare

    def test_prepares_the_final_merged_artifact_with_the_original_exec_pid(self):
        code, argv, _log, stderr, *_ = run_wrapper(
            socket_state="live",
            argv=["--settings", '{"effortLevel":"max","env":{"KEEP":"1"}}', "hello"],
            generated_hook_settings=generated_claude_hook_settings(),
            setup_sandbox=self.setup("copy"),
        )
        self.assertEqual(code, 0, stderr)
        self.assertTrue(self.args.exists(), "wrapper never invoked final readiness preparation")
        args = self.args.read_text().splitlines()
        self.assertEqual(args[:3], ["hooks", "claude", "prepare-readiness"])
        self.assertEqual(args[args.index("--root-pid") + 1], self.pid.read_text().strip())
        before = json.loads(self.settings.read_text())
        self.assertEqual(before["effortLevel"], "max")
        self.assertEqual(before["env"]["KEEP"], "1")
        self.assertEqual(Path(argv[argv.index("--settings") + 1]).name, "shepherd-prepared.json")
        self.assertEqual(parse_settings_arg(argv), before)

    def test_registration_failure_refuses_launch_instead_of_falling_back(self):
        code, argv, _log, stderr, *_ = run_wrapper(
            socket_state="live", argv=["hello"],
            generated_hook_settings=generated_claude_hook_settings(),
            setup_sandbox=self.setup("fail"),
        )
        self.assertNotEqual(code, 0)
        self.assertNotIn("hello", argv)
        self.assertNotIn("--session-id", argv)
        self.assertFalse(self.pid.exists())
        self.assertIn("not started", stderr)

    def test_invalid_prepared_artifact_refuses_launch(self):
        code, argv, _log, stderr, *_ = run_wrapper(
            socket_state="live", argv=["hello"],
            generated_hook_settings=generated_claude_hook_settings(),
            setup_sandbox=self.setup("invalid"),
        )
        self.assertNotEqual(code, 0)
        self.assertNotIn("hello", argv)
        self.assertNotIn("--session-id", argv)
        self.assertFalse(self.pid.exists())
        self.assertIn("not started", stderr)

    def test_legacy_cli_has_no_new_readiness_failure_surface(self):
        legacy = json.loads(generated_claude_hook_settings())
        legacy.pop("__cmux")
        code, argv, _log, stderr, *_ = run_wrapper(
            socket_state="live", argv=["hello"],
            generated_hook_settings=json.dumps(legacy, sort_keys=True, separators=(",", ":")),
            setup_sandbox=self.setup("fail"),
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn("hello", argv)
        self.assertFalse(self.args.exists())

    def test_unqualified_build_has_no_preparation_failure_surface(self):
        code, argv, _log, stderr, *_ = run_wrapper(
            socket_state="live", argv=["hello"],
            generated_hook_settings=generated_claude_hook_settings(),
            setup_sandbox=self.setup("fail", qualify=False),
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn("hello", argv)
        self.assertFalse(self.args.exists())

    def test_master_opt_out_still_starts_no_readiness_work(self):
        code, argv, log, stderr, *_ = run_wrapper(
            socket_state="live", argv=["hello"], hooks_disabled=True,
            generated_hook_settings=generated_claude_hook_settings(),
            setup_sandbox=self.setup("fail"),
        )
        self.assertEqual(code, 0, stderr)
        self.assertEqual(argv, ["hello"])
        self.assertEqual(log, [])
        self.assertFalse(self.args.exists())


if __name__ == "__main__":
    unittest.main()
