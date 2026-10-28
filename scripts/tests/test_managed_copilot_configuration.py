"""The native fixed-profile readback policy rejects unknown and inherited capability domains."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
CASES = (
    ("agents", "session.agent.list", {"agents": []}),
    ("currentAgent", "session.agent.getCurrent", {"agent": None}),
    ("mcp", "session.mcp.listConfigured", {"servers": []}),
    ("plugins", "session.plugins.list", {"plugins": []}),
    ("extensions", "session.extensions.list", {"extensions": []}),
    ("initializeTools", "session.tools.initializeAndValidate", {}),
    ("tools", "session.tools.getCurrentMetadata", {"tools": []}),
)


class ManagedCopilotConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-copilot-readback-source-"))
        print(f"Retained exact-source readback build: {cls.build}", file=sys.stderr)
        cls.executable = cls.build / "readback"
        command = [
            "swiftc", "-swift-version", "6", "-gnone", "-parse-as-library",
            "-module-cache-path", str(MODULE_CACHE or cls.build / "cache"),
            str(ROOT / "Sources/Panels/CopilotManagedConfiguration.swift"),
            str(ROOT / "scripts/tests/fixtures/managed_copilot_configuration_main.swift"),
            "-o", str(cls.executable),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def readback(self, name, result):
        reply = subprocess.run(
            [str(self.executable)], input=json.dumps({"readback": name, "result": result}),
            capture_output=True, text=True, timeout=3,
        )
        self.assertEqual(reply.returncode, 0, reply.stderr)
        return json.loads(reply.stdout)

    def test_each_readback_uses_the_pinned_session_scoped_rpc(self):
        for name, method, result in CASES:
            with self.subTest(name=name):
                reply = self.readback(name, result)
                self.assertEqual(reply["method"], method)

    def test_explicit_empty_domains_are_accepted_individually(self):
        for name, _, result in CASES:
            with self.subTest(name=name):
                self.assertTrue(self.readback(name, result)["accepted"])

    def test_absence_is_not_an_empty_inventory(self):
        for name, _, result in CASES:
            if not result:
                continue
            with self.subTest(name=name):
                self.assertFalse(self.readback(name, {})["accepted"])

    def test_null_or_wrongly_typed_inventory_is_not_empty(self):
        for name, _, result in CASES:
            if name in ("initializeTools", "currentAgent"):
                continue
            key = next(iter(result))
            for value in (None, {}, "", 0, False):
                with self.subTest(name=name, value=value):
                    self.assertFalse(self.readback(name, {key: value})["accepted"])

    def test_uninitialized_tool_metadata_does_not_pass_the_noop_initialization_barrier(self):
        self.assertFalse(self.readback("tools", {"tools": None})["accepted"])

    def test_any_inherited_capability_holds_the_empty_domain(self):
        for name, key in (("agents", "agents"), ("mcp", "servers"), ("plugins", "plugins"),
                          ("extensions", "extensions"), ("tools", "tools")):
            with self.subTest(name=name):
                self.assertFalse(self.readback(name, {key: [{"name": "unexpected"}]})["accepted"])

    def test_current_agent_requires_explicit_default_not_a_falsey_substitute(self):
        for value in (False, "", [], {}, {"name": "custom"}):
            with self.subTest(value=value):
                self.assertFalse(self.readback("currentAgent", {"agent": value})["accepted"])

    def test_unaccounted_readback_fields_cannot_expand_the_fixed_profile(self):
        for name, _, result in CASES:
            with self.subTest(name=name):
                self.assertFalse(self.readback(name, {**result, "unaccounted": []})["accepted"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
