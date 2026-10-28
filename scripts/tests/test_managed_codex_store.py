"""The actual Store, with owned controlled peers and no app/provider/model qualification."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_managed_codex_session import SOURCE_NAMES as SESSION_SOURCES, FOUNDATION_NAMES, CONTROL_NAMES
from test_managed_codex_startup import descriptor, ready


ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
STORE_SOURCES = [
    "Sources/AgentSessionProvider.swift", "Sources/AgentSessionLaunchPlan.swift",
    "Sources/Panels/AgentSessionProcessStore.swift", "Sources/Panels/AgentSessionRunningSession.swift",
    "Sources/Panels/AgentSessionBridgeError.swift", "Sources/Panels/AgentSessionStartedSession.swift",
    "Sources/Panels/AgentSessionBridge.swift",
    "Sources/Panels/AgentSessionInputWriter.swift", "Sources/Panels/AgentSessionOutputLineBuffer.swift",
    "Sources/Panels/AgentSessionPermissionMode.swift", "Sources/Panels/AgentSessionStreamAccumulators.swift",
    "Sources/Panels/ClaudeStreamJSONAccumulator.swift", "Sources/Panels/OpenCodeEventStreamParser.swift",
    "Sources/Panels/OpenCodeEventTextAccumulator.swift", "Sources/Panels/OpenCodeProcessOutputDisposition.swift",
    "Sources/Panels/CodexAppServerSession.swift", "Sources/Panels/CodexAppServerQueuedInput.swift",
    "Sources/Panels/AgentSessionManagedCodexLaunch.swift",
    "scripts/tests/fixtures/managed_codex_store.swift",
    "scripts/tests/fixtures/managed_copilot_startup.swift",
    "scripts/tests/fixtures/managed_session_lifetime.swift",
]
SETTINGS_SOURCES = [
    "Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/CmuxStateDirectory.swift",
    "scripts/tests/fixtures/managed_store_settings.swift",
]


class ManagedCodexStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-codex-store-source-"))
        print(f"Retained exact Store composition fixture: {cls.build}", file=sys.stderr)
        flags = ["swiftc", "-swift-version", "5", "-gnone", "-D", "SHEPHERD_SOURCE_TEST",
                 "-D", "SHEPHERD_STORE_SOURCE_TEST",
                 "-module-cache-path", str(MODULE_CACHE or cls.build / "cache")]
        commands = []
        for module, names, dependencies in (
            ("CmuxFoundation", FOUNDATION_NAMES, []),
            ("CmuxControlSocket", CONTROL_NAMES, ["CmuxFoundation"]),
            ("CmuxSettings", SETTINGS_SOURCES, []),
        ):
            commands.append(flags + ["-emit-library", "-emit-module", "-module-name", module,
                "-I", str(cls.build), "-L", str(cls.build),
                *("-l" + dependency for dependency in dependencies),
                *(str(ROOT / name) for name in names), "-o", str(cls.build / f"lib{module}.dylib")])
        sources = list(dict.fromkeys(SESSION_SOURCES + STORE_SOURCES))
        commands.append(flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build),
            "-lCmuxFoundation", "-lCmuxControlSocket", "-lCmuxSettings", "-Xlinker", "-rpath",
            "-Xlinker", str(cls.build), *(str(ROOT / name) for name in sources),
            "-o", str(cls.build / "store")])
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "store"

    def run_store(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-codex-store", scenario],
            input=json.dumps({"scenario": scenario, "descriptor": descriptor(), "ready": ready()}),
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_store_projects_codex_identity_owner_work_and_verified_close_without_copilot_labels(self):
        result = self.run_store("owner")
        self.assertEqual(result["startError"], "", "CMUX_NATIVE_CODEX_STORE_UNAVAILABLE: " + str(result))
        self.assertTrue(result["owned"], result)
        self.assertEqual(result["provider"], "codex", result)
        self.assertTrue(result["identityMatches"], result)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["assistant"], "controlled assistant: 雪\n\n", result)
        self.assertEqual(result["turnCompletions"], 1, result)
        self.assertTrue(result["eventsMatchSession"], result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["exitStatuses"], [0], result)

    def test_store_refuses_foreign_owner_store_or_unqualified_production_before_peer_start(self):
        for scenario in ("wrong-provider", "foreign-store", "production-unqualified"):
            with self.subTest(scenario=scenario):
                result = self.run_store(scenario)
                self.assertTrue(result["startError"], result)
                self.assertFalse(result["peerStarted"], result)
                self.assertFalse(result["providerStarted"], result)
                self.assertTrue(result["stopped"], result)

    def test_codex_reserves_the_same_store_slot_against_both_managed_and_manual_starts(self):
        result = self.run_store("mixed-slot")
        self.assertEqual(result["startError"], "", "CMUX_NATIVE_CODEX_STORE_UNAVAILABLE: " + str(result))
        self.assertEqual(result["managedDuplicateError"], "sessionAlreadyRunning", result)
        self.assertEqual(result["manualDuplicateError"], "sessionAlreadyRunning", result)
        self.assertTrue(result["complete"], result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["exitStatuses"], [0], result)

    def test_store_keeps_native_command_projection_and_revocation_bound_to_codex(self):
        for scenario, failed in (("command", False), ("revoked", True)):
            with self.subTest(scenario=scenario):
                result = self.run_store(scenario)
                self.assertEqual(result["startError"], "", "CMUX_NATIVE_CODEX_STORE_UNAVAILABLE: " + str(result))
                self.assertTrue(result["completeBeforeClose"], result)
                self.assertTrue(result["eventsMatchSession"], result)
                self.assertTrue(result["stopped"], result)
                self.assertEqual(result["exitStatuses"], [1 if failed else 0], result)
                if not failed:
                    self.assertEqual(result["commandStatuses"], ["inProgress", "completed"], result)
                    self.assertEqual(result["executions"], "A\n", result)
                else:
                    self.assertTrue(result["revocationReported"], result)

    def test_shared_store_preserves_actual_copilot_start_commands_projection_and_close(self):
        result = self.run_store("copilot-control")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["owned"], result)
        self.assertEqual(result["provider"], "copilot", result)
        self.assertTrue(result["identityMatches"], result)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["assistant"], "Done\n\n", result)
        self.assertEqual(result["executions"], "read\nedit\nvalidate\n", result)
        self.assertEqual(result["projectContents"], "after\n", result)
        self.assertEqual(result["commandStatuses"], [
            "inProgress", "completed", "inProgress", "completed", "inProgress", "completed",
        ], result)
        self.assertTrue(result["eventsMatchSession"], result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["exitStatuses"], [0], result)


if __name__ == "__main__":
    unittest.main()
