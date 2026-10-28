"""Actual owned launch/adapter/command composition with a controlled peer, never a provider."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_managed_codex_startup import descriptor, ready


ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
SOURCE_NAMES = [
    "CLI/CodexTeamsPOSIXSupport.swift", "CLI/OwnedProcessSupervisor.swift",
    "Sources/Panels/AgentSessionOwnedProcessLauncher.swift",
    "Sources/Panels/AgentSessionManagedSession.swift",
    "Sources/Panels/AgentSessionManagedCommand.swift",
    "Sources/Panels/AgentSessionManagedCopilotLaunch.swift",
    "Sources/Panels/AgentSessionManagedNativeOwner.swift",
    "Sources/Panels/AgentSessionManagedProviderAdapter.swift",
    "Sources/Panels/AgentSessionManagedRendererController.swift",
    "Sources/Panels/AgentSessionManagedRendererReservation.swift",
    "Sources/Panels/AgentSessionManagedCommandService.swift",
    "Sources/Panels/CopilotManagedSession.swift",
    "Sources/Panels/CopilotManagedConfiguration.swift",
    "Sources/Panels/CopilotManagedEventMetadata.swift",
    "Sources/Panels/CopilotManagedTurnLedger.swift",
    "Sources/Panels/AgentSessionManagedJSON.swift",
    "Sources/Panels/CodexManagedStreamDecoder.swift",
    "Sources/Panels/CodexManagedShellInventory.swift",
    "Sources/Panels/CodexManagedTurnLedger.swift",
    "Sources/Panels/CodexManagedSession.swift",
    "Sources/Panels/CodexManagedStartup.swift",
    "scripts/tests/fixtures/managed_codex_session.swift",
]
FOUNDATION_NAMES = [
    "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/" + name
    for name in ("AgentPIDProcessIdentity.swift", "DarwinProcessEnumerator.swift",
                 "DarwinProcessInfoReader.swift", "DarwinProcessListing.swift")
] + ["scripts/tests/fixtures/managed_process_listing.swift"]
CONTROL_NAMES = [
    "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd/" + name
    for name in ("ShepherdHookExecutableIdentity.swift", "ShepherdManagedBackendLaunchReceipt.swift",
                 "ShepherdManagedBootstrapReader.swift", "ShepherdManagedPipeWriter.swift",
                 "ShepherdManagedRPCFramer.swift", "ShepherdManagedSessionIdentity.swift",
                 "ShepherdManagedSessionState.swift")
]


class ManagedCodexSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-codex-session-source-"))
        print(f"Retained exact-source Codex composition fixture: {cls.build}", file=sys.stderr)
        flags = ["swiftc", "-swift-version", "6", "-gnone", "-D", "SHEPHERD_SOURCE_TEST",
                 "-module-cache-path", str(MODULE_CACHE or cls.build / "cache")]
        sources = [ROOT / name for name in SOURCE_NAMES]
        launch = ROOT / "Sources/Panels/AgentSessionManagedCodexLaunch.swift"
        if launch.exists():
            sources.append(launch)
        commands = [
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxFoundation",
                     *(str(ROOT / name) for name in FOUNDATION_NAMES),
                     "-o", str(cls.build / "libCmuxFoundation.dylib")],
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxControlSocket",
                     "-I", str(cls.build), "-L", str(cls.build), "-lCmuxFoundation",
                     *(str(ROOT / name) for name in CONTROL_NAMES),
                     "-o", str(cls.build / "libCmuxControlSocket.dylib")],
            flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build),
                     "-lCmuxFoundation", "-lCmuxControlSocket", "-Xlinker", "-rpath",
                     "-Xlinker", str(cls.build), *map(str, sources),
                     "-o", str(cls.build / "session")],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "session"

    def run_session(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-codex-session", scenario],
            input=json.dumps({"scenario": scenario, "descriptor": descriptor(), "ready": ready()}),
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        decoded = json.loads(result.stdout)
        if scenario not in ("wrong-provider", "unconsumed-owner", "revoked-owner", "wrong-scope",
                            "production-unqualified"):
            self.assertFalse(decoded.get("rejected", False),
                             "CMUX_NATIVE_CODEX_ADAPTER_UNAVAILABLE: " + str(decoded))
        return decoded

    def test_actual_descriptor_binds_helper_lifetime_and_returned_thread_without_qualification(self):
        result = self.run_session("startup")
        self.assertTrue(result["configured"], result)
        self.assertEqual(result["boundThread"], "actual-controlled-sdk-thread", result)
        self.assertTrue(result["profileMatches"], result)
        self.assertFalse(result["reactQualified"], result)
        self.assertFalse(result["solidQualified"], result)
        self.assertNotEqual(result["backendPID"], result["supervisorPID"], result)
        self.assertEqual(result["peerMethods"], ["cmux/initialize"], result)

    def test_foreign_unconsumed_revoked_or_wrong_scope_owner_never_starts_a_peer(self):
        for scenario in ("wrong-provider", "unconsumed-owner", "revoked-owner", "wrong-scope",
                         "production-unqualified"):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                self.assertTrue(result["rejected"], result)
                self.assertFalse(result["peerStarted"], result)

    def test_owner_input_joins_actual_full_write_and_returned_turn_before_empty_inventory(self):
        result = self.run_session("owner")
        self.assertTrue(result["inputAccepted"], result)
        self.assertFalse(result["secondAccepted"], result)
        self.assertTrue(result["ackMatchesHost"], result)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["outstanding"], 0, result)
        self.assertEqual(result["peerMethods"], ["cmux/initialize", "turn/start", "thread/backgroundTerminals/list"], result)
        self.assertEqual(result["projections"], [
            {"kind": "assistant", "text": "controlled assistant: 雪"},
            {"kind": "turnComplete"},
        ], result)

    def test_foreground_commands_use_kept_service_exact_result_nonce_and_known_exit_status(self):
        for scenario, status in (("command", 0), ("command-failed", 7)):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                self.assertTrue(result["complete"], result)
                self.assertEqual(result["executions"], "A\n", result)
                self.assertEqual(result["nativeOutstanding"], 0, result)
                report = result["peerResults"][0]
                self.assertTrue(report["nonceValid"], result)
                self.assertEqual(report["success"], status == 0, result)
                self.assertEqual(report["report"]["status"], status, result)
                self.assertEqual(report["report"]["decoding"], "base64", result)
                self.assertIs(report["report"].get("stdoutTruncated"), False,
                              "CMUX_NATIVE_CODEX_OUTPUT_REPORT_UNAVAILABLE: stdout truncation flag")
                self.assertIs(report["report"].get("stderrTruncated"), False,
                              "CMUX_NATIVE_CODEX_OUTPUT_REPORT_UNAVAILABLE: stderr truncation flag")
                self.assertEqual(base64.b64decode(report["report"]["stdout"]), "native output: 雪\n".encode())
                self.assertEqual(base64.b64decode(report["report"]["stderr"]), b"native diagnostic\n")
                self.assertEqual([p["kind"] for p in result["projections"]],
                                 ["commandStarted", "commandCompleted", "assistant", "turnComplete"], result)

    def test_valid_large_command_output_has_bounded_binary_safe_report_and_exactly_one_execution(self):
        for scenario, stdout_bytes, stderr_bytes, stdout_value, stderr_value in (
            ("command-output-200k", 204800, 0, b"A", b""),
            ("command-output-both-limits", 262144, 262144, b"\xff", b"\xfe"),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                diagnostic = {
                    key: result[key] for key in (
                        "configured", "complete", "reason", "executions", "outstanding",
                        "nativeOutstanding", "peerMethods", "cleanupError",
                    )
                }
                diagnostic["peerResultCount"] = len(result["peerResults"])
                self.assertTrue(result["inputAccepted"], diagnostic)
                self.assertFalse(result["secondAccepted"], diagnostic)
                self.assertTrue(result["complete"],
                                "CMUX_NATIVE_CODEX_OUTPUT_REPORT_UNAVAILABLE: " + str(diagnostic))
                self.assertEqual(result["reason"], "", diagnostic)
                self.assertEqual(result["executions"], "A\n", diagnostic)
                self.assertEqual(result["nativeOutstanding"], 0, diagnostic)
                self.assertEqual(result["outstanding"], 0, diagnostic)
                self.assertEqual(result["cleanupError"], "", diagnostic)
                self.assertEqual(len(result["peerResults"]), 1, diagnostic)
                callback = result["peerResults"][0]
                self.assertTrue(callback["nonceValid"], diagnostic)
                self.assertTrue(callback["success"], diagnostic)
                self.assertGreater(callback["reportUTF8Bytes"], 0, diagnostic)
                self.assertLessEqual(callback["reportUTF8Bytes"], 262144, diagnostic)
                report = callback["report"]
                self.assertEqual(report["status"], 0, diagnostic)
                self.assertEqual(report["decoding"], "base64", diagnostic)
                for stream, count, value in (
                    ("stdout", stdout_bytes, stdout_value), ("stderr", stderr_bytes, stderr_value),
                ):
                    self.assertEqual(report[stream + "Bytes"], count, diagnostic)
                    self.assertIs(report.get(stream + "Truncated"), count > 16384, diagnostic)
                    self.assertEqual(
                        base64.b64decode(report[stream], validate=True), value * min(count, 16384),
                        diagnostic,
                    )
                self.assertEqual(result["peerMethods"], [
                    "cmux/initialize", "turn/start", "thread/backgroundTerminals/list",
                ], diagnostic)
                self.assertEqual([p["kind"] for p in result["projections"]], [
                    "commandStarted", "commandCompleted", "assistant", "turnComplete",
                ], diagnostic)
                self.assertEqual(result["projections"][1]["status"], 0, diagnostic)

    def test_command_output_above_raw_stream_limit_still_holds_without_callback_or_retry(self):
        result = self.run_session("command-output-overflow")
        self.assertFalse(result["complete"], result)
        self.assertEqual(result["reason"], "commandHeld:outputLimit", result)
        self.assertEqual(result["executions"], "A\n", result)
        self.assertGreater(result["outstanding"], 0, result)
        self.assertEqual(result["nativeOutstanding"], 1, result)
        self.assertEqual(result["peerResults"], [], result)
        self.assertEqual(result["peerMethods"], ["cmux/initialize", "turn/start"], result)
        self.assertEqual(result["peerInputs"], ["controlled owner: 雪"], result)
        self.assertEqual([p["kind"] for p in result["projections"]], ["commandStarted"], result)

    def test_backend_fallback_or_wrong_result_echo_never_clears_callback_work(self):
        for scenario in ("command-fallback", "command-wrong-echo"):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                self.assertFalse(result["complete"], result)
                self.assertTrue(result["reason"], result)
                self.assertGreater(result["outstanding"], 0, result)
                self.assertEqual(result["executions"], "A\n", result)

    def test_overlapping_callbacks_are_serialized_through_the_same_kept_command_service(self):
        result = self.run_session("command-overlap")
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["executions"], "A\nB\n", result)
        self.assertEqual(result["nativeOutstanding"], 0, result)
        self.assertEqual(len(result["peerResults"]), 2, result)
        self.assertTrue(all(row["nonceValid"] for row in result["peerResults"]), result)
        self.assertNotEqual(result["peerResults"][0]["nonce"], result["peerResults"][1]["nonce"], result)

    def test_revocation_preserves_unknown_physical_work_and_refuses_completion(self):
        result = self.run_session("command-revoked")
        self.assertFalse(result["complete"], result)
        self.assertTrue(result["reason"], result)
        self.assertGreater(result["outstanding"], 0, result)
        self.assertEqual(result["nativeOutstanding"], 1, result)
        self.assertTrue(result["cleanupError"], result)
        self.assertEqual(result["peerResults"], [], result)

    def test_late_old_ack_or_descriptor_drift_cannot_create_positive_evidence(self):
        for scenario in ("late-ack", "wrong-descriptor"):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                self.assertFalse(result["complete"], result)
                self.assertTrue(result["reason"], result)
                if scenario == "wrong-descriptor":
                    self.assertNotIn("turnComplete", [p["kind"] for p in result["projections"]], result)

    def test_supervisor_custody_joins_literal_input_full_write_and_actual_returned_turn(self):
        result = self.run_session("supervisor")
        self.assertTrue(result["ownerComplete"], result)
        self.assertTrue(result["supervisorAccepted"], result)
        self.assertFalse(result["repeatedSupervisorAccepted"], result)
        self.assertTrue(result["progressScopeMatches"], result)
        self.assertEqual(result["progress"], [
            {"inserted": True, "written": False, "provider": "", "failure": ""},
            {"inserted": True, "written": True, "provider": "", "failure": ""},
            {"inserted": True, "written": True, "provider": "controlled-turn-B", "failure": ""},
        ], result)
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["outstanding"], 0, result)
        self.assertEqual(result["peerMethods"], [
            "cmux/initialize", "turn/start", "thread/backgroundTerminals/list",
            "turn/start", "thread/backgroundTerminals/list",
        ], result)
        self.assertEqual(result["peerInputs"], ["controlled owner: 雪", "Continue authorized coding: 雪"], result)

    def test_foreign_or_cancelled_supervisor_custody_never_emits_another_input(self):
        for scenario in ("supervisor-foreign-store", "supervisor-foreign-owner", "supervisor-cancelled"):
            with self.subTest(scenario=scenario):
                result = self.run_session(scenario)
                self.assertTrue(result["ownerComplete"], result)
                self.assertFalse(result["supervisorAccepted"], result)
                self.assertEqual(result["progress"], [], result)
                self.assertTrue(result["complete"], result)
                self.assertEqual(result["peerMethods"],
                                 ["cmux/initialize", "turn/start", "thread/backgroundTerminals/list"], result)
                self.assertEqual(result["peerInputs"], ["controlled owner: 雪"], result)

    def test_activity_during_real_partial_supervisor_write_cannot_publish_full_write_or_ack(self):
        result = self.run_session("supervisor-partial")
        self.assertTrue(result["ownerComplete"], result)
        self.assertTrue(result["supervisorAccepted"], result)
        self.assertGreater(result["partialBytes"], 0, result)
        self.assertFalse(result["complete"], result)
        self.assertTrue(result["reason"], result)
        self.assertTrue(result["progressScopeMatches"], result)
        self.assertGreaterEqual(len(result["progress"]), 2, result)
        self.assertTrue(all(p["inserted"] and not p["written"] and not p["provider"]
                            for p in result["progress"]), result)
        self.assertTrue(result["progress"][-1]["failure"], result)
        self.assertEqual(result["peerMethods"],
                         ["cmux/initialize", "turn/start", "thread/backgroundTerminals/list"], result)
        self.assertEqual(result["peerInputs"], ["controlled owner: 雪"], result)


if __name__ == "__main__":
    unittest.main()
