"""Run the actual ProcessStore with owned controlled children, never providers or a GUI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedProcessStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-store-source-"))
        source = cls.build / "Sources/StoreFixture"
        source.mkdir(parents=True)
        print(f"Retained actual ProcessStore source package: {cls.build}", file=sys.stderr)
        names = [
            "CLI/CodexTeamsPOSIXSupport.swift", "CLI/OwnedProcessSupervisor.swift",
            "Sources/App/DebugLogging.swift",
            "Sources/AgentSessionProvider.swift", "Sources/AgentSessionLaunchPlan.swift",
            "Sources/Panels/AgentSessionProcessStore.swift", "Sources/Panels/AgentSessionRunningSession.swift",
            "Sources/Panels/AgentSessionBridge.swift", "Sources/Panels/AgentSessionBridgeError.swift",
            "Sources/Panels/AgentSessionBridgeRequest.swift",
            "Sources/Panels/AgentSessionStartedSession.swift", "Sources/Panels/AgentSessionInputWriter.swift",
            "Sources/Panels/AgentSessionOutputLineBuffer.swift", "Sources/Panels/AgentSessionPermissionMode.swift",
            "Sources/Panels/AgentSessionStreamAccumulators.swift", "Sources/Panels/ClaudeStreamJSONAccumulator.swift",
            "Sources/Panels/OpenCodeEventStreamParser.swift", "Sources/Panels/OpenCodeEventTextAccumulator.swift",
            "Sources/Panels/OpenCodeProcessOutputDisposition.swift", "Sources/Panels/CodexAppServerSession.swift",
            "Sources/Panels/CodexAppServerQueuedInput.swift", "Sources/Panels/AgentSessionOwnedProcessLauncher.swift",
            "Sources/Panels/AgentSessionManagedSession.swift", "Sources/Panels/AgentSessionManagedCommand.swift",
            "Sources/Panels/AgentSessionManagedCopilotLaunch.swift",
            "Sources/Panels/AgentSessionManagedCommandService.swift", "Sources/Panels/CopilotManagedSession.swift",
            "Sources/Panels/CopilotManagedConfiguration.swift", "Sources/Panels/CopilotManagedEventMetadata.swift",
            "Sources/Panels/CopilotManagedTurnLedger.swift",
            "scripts/tests/fixtures/managed_session_lifetime.swift",
            "scripts/tests/fixtures/managed_command_service.swift",
            "scripts/tests/fixtures/managed_copilot_startup.swift",
            "scripts/tests/fixtures/managed_process_store.swift",
        ]
        for name in names:
            shutil.copy2(ROOT / name, source)
        packages = ["CmuxFoundation", "CmuxControlSocket", "CmuxSettings", "CMUXDebugLog"]
        dependencies = ",\n".join(
            f'.package(path: "{ROOT / "Packages/macOS" / name}")' for name in packages
        )
        products = ",\n".join(
            f'.product(name: "{name}", package: "{name}")' for name in packages
        )
        (cls.build / "Package.swift").write_text(f"""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ManagedStoreSource", platforms: [.macOS(.v14)],
    dependencies: [{dependencies}],
    targets: [.executableTarget(name: "StoreFixture", dependencies: [{products}])],
    swiftLanguageModes: [.v5])
""")
        scratch = os.environ.get("SHEPHERD_STORE_SOURCE_SCRATCH", str(cls.build / "build"))
        command = [
            "swift", "build", "--package-path", str(cls.build), "--scratch-path", scratch,
            "--build-system", "native", "--disable-index-store", "--jobs", "2",
            "-Xswiftc", "-gnone", "-Xswiftc", "-D", "-Xswiftc", "SHEPHERD_SOURCE_TEST",
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=240)
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Actual-source build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])
        cls.executable = Path(scratch) / "debug/StoreFixture"

    def run_store(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-store", scenario],
            capture_output=True, text=True, timeout=15,
        )
        evidence = self.build / f"{scenario}.json"
        evidence.write_text(json.dumps({
            "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
        }, indent=2))
        self.assertEqual(result.returncode, 0, evidence.read_text())
        return json.loads(result.stdout)

    def test_native_managed_start_is_owned_and_blocks_a_manual_start(self):
        result = self.run_store("start-owned")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["activeAfterStart"], result)
        self.assertTrue(result["peerStarted"], result)
        self.assertEqual(result["manualStartError"], "sessionAlreadyRunning", result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["exitStatus"], 0, result)
        self.assertTrue(result["exitStopRequested"], result)

    def test_copilot_identity_does_not_describe_a_generic_manual_launch(self):
        result = self.run_store("copilot-provider-contract")
        self.assertTrue(result["supported"], result)
        self.assertEqual(result["executableName"], "copilot", result)
        self.assertEqual(result["transportKind"], "managed-stdio-jsonrpc", result)
        self.assertEqual(result["arguments"], [], result)
        self.assertFalse(result["autoStart"], result)

    def test_generic_copilot_start_is_refused_before_session_or_child_creation(self):
        result = self.run_store("copilot-manual-refused")
        self.assertEqual(result["startError"], "unsupportedTransport", result)
        self.assertFalse(result["active"], result)
        self.assertFalse(result["started"], result)
        self.assertTrue(result["stopped"], result)

    def test_browser_requests_cannot_select_or_start_the_managed_provider(self):
        result = self.run_store("copilot-browser-refused")
        self.assertTrue(result["supported"], result)
        self.assertEqual(result["errors"], ["invalidProvider", "invalidProvider"], result)
        self.assertEqual(result["manualProviders"], ["codex", "claude", "opencode"], result)

    def test_raw_native_scope_and_mandate_cannot_grant_coding_execution(self):
        result = self.run_store("raw-coding-mandate-refused")
        self.assertEqual(result["startError"], "unsupportedTransport", result)
        self.assertFalse(result["activeAfterStart"], result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["stopped"], result)

    def test_native_coding_owner_runs_real_read_edit_validate_under_one_owned_launch(self):
        result = self.run_store("native-coding-input")
        self.assertTrue(result["nativeOwnerAvailable"], result)
        self.assertEqual(result["startError"], "", result)
        self.assertEqual(result["inputError"], "", result)
        self.assertTrue(result["peerStarted"], result)
        self.assertTrue(result["wireSendObserved"], result)
        self.assertTrue(result["workReadbacksObserved"], result)
        self.assertEqual(result["projectContents"], "after\n", result)
        self.assertEqual(result["commandExecutions"], "read\nedit\nvalidate\n", result)
        self.assertEqual(result["reservedSnapshot"]["status"], "starting", result)
        self.assertEqual(result["runningSnapshot"]["status"], "running", result)
        self.assertEqual(result["runningSnapshot"]["providerId"], "copilot", result)
        self.assertEqual(result["runningSnapshot"]["sessionId"], result["sessionID"], result)
        self.assertIn("no sandbox", result["runningSnapshot"]["executionDisclosure"], result)
        self.assertTrue(result["snapshotCleared"], result)
        self.assertTrue(result["stopped"], result)

    def test_revoked_or_foreign_native_coding_owners_never_launch_a_child(self):
        for scenario in [
            "revoked", "other-store", "wrong-workspace", "wrong-surface", "wrong-generation",
            "wrong-host", "wrong-mandate", "wrong-directory",
        ]:
            with self.subTest(scenario=scenario):
                result = self.run_store("native-coding-" + scenario)
                self.assertTrue(result["nativeOwnerAvailable"], result)
                self.assertEqual(result["startError"], "unsupportedTransport", result)
                self.assertFalse(result["activeAfterStart"], result)
                self.assertFalse(result["peerStarted"], result)
                self.assertTrue(result["stopped"], result)

    def test_current_native_owner_is_rechecked_after_awaited_preparation(self):
        result = self.run_store("native-coding-owner-lost-before-launch")
        self.assertTrue(result["nativeOwnerAvailable"], result)
        self.assertNotEqual(result["startError"], "", result)
        self.assertFalse(result["activeAfterStart"], result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["stopped"], result)

    def test_current_native_owner_is_rechecked_before_owner_input(self):
        result = self.run_store("native-coding-owner-lost")
        self.assertEqual(result["startError"], "", result)
        self.assertNotEqual(result["inputError"], "", result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertEqual(result["projectContents"], "before\n", result)
        self.assertTrue(result["stopped"], result)

    def test_native_coding_revocation_synchronously_blocks_queued_input(self):
        result = self.run_store("native-coding-close-queued-input")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["queuedInputRejected"], result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertEqual(result["commandExecutions"], "", result)
        self.assertTrue(result["stopped"], result)

    def test_native_coding_capability_cannot_be_reused_after_a_normal_close(self):
        result = self.run_store("native-coding-replay")
        self.assertEqual(result["startError"], "", result)
        self.assertEqual(result["replayError"], "unsupportedTransport", result)
        self.assertTrue(result["stopped"], result)

    def test_failed_native_cleanup_projects_typed_lifecycle_without_falsely_releasing_ownership(self):
        result = self.run_store("native-coding-cleanup-unknown")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["failureReported"], result)
        self.assertTrue(result["occupiedAfterFailure"], result)
        self.assertFalse(result["exitReported"], result)
        self.assertTrue(result["fixtureBackendAbsent"], result)
        self.assertTrue(any(
            event["nativeSession"]["status"] == "failed"
            and event["nativeSession"]["sessionId"] == result["runningSnapshot"]["sessionId"]
            for event in result["nativeLifecycleEvents"]
        ), result)

    def test_close_during_preparation_never_launches_a_late_backend(self):
        result = self.run_store("cancel-preparation")
        self.assertTrue(result["observedReservation"], result)
        self.assertEqual(result["startError"], "CancellationError()", result)
        self.assertFalse(result["activeAfterStart"], result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["stopped"], result)

    def test_reservation_rejects_a_duplicate_while_preparing(self):
        result = self.run_store("duplicate-preparation")
        self.assertEqual(result["startError"], "", result)
        self.assertEqual(result["duplicateError"], "sessionAlreadyRunning", result)
        self.assertTrue(result["stopped"], result)

    def test_sync_stop_revokes_a_queued_owner_input_before_its_task_runs(self):
        result = self.run_store("stop-queued-input")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["queuedInputRejected"], result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertTrue(result["stopped"], result)

    def test_close_while_native_hash_preparation_is_awaited_cannot_launch_late(self):
        result = self.run_store("cancel-awaiting-preparation")
        self.assertTrue(result["observedReservation"], result)
        self.assertEqual(result["startError"], "CancellationError()", result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["stopped"], result)

    def test_owner_input_uses_the_actual_managed_pipe_without_a_manual_fallback(self):
        result = self.run_store("owner-input")
        self.assertEqual(result["startError"], "", result)
        self.assertEqual(result["ownerInputError"], "", result)
        self.assertTrue(result["wireSendObserved"], result)
        self.assertTrue(result["workReadbacksObserved"], result)
        self.assertTrue(result["stopped"], result)
        self.assertEqual(result["exitStatus"], 0, result)
        self.assertTrue(result["exitStopRequested"], result)

    def test_manual_session_still_runs_and_blocks_a_managed_start(self):
        result = self.run_store("manual-first")
        self.assertEqual(result["manualStartError"], "", result)
        self.assertEqual(result["startError"], "sessionAlreadyRunning", result)
        self.assertTrue(result["manualInputObserved"], result)
        self.assertTrue(result["stopped"], result)

    def test_unverified_cleanup_retains_ownership_and_reports_the_error(self):
        result = self.run_store("cleanup-unknown")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["cleanupErrorReported"], result)
        self.assertTrue(result["activeAfterFailedClose"], result)
        self.assertEqual(result["manualStartError"], "sessionAlreadyRunning", result)
        self.assertTrue(result["fixtureBackendAbsent"], result)

    def test_failed_startup_reports_failure_not_a_successful_owner_stop(self):
        result = self.run_store("startup-held")
        self.assertEqual(result["startError"], "providerNotReady", result)
        self.assertEqual(result["exitStatus"], 1, result)
        self.assertFalse(result["exitStopRequested"], result)
        self.assertTrue(result["startupErrorReported"], result)
        self.assertFalse(result["activeAfterStart"], result)
        self.assertTrue(result["stopped"], result)

    def test_post_start_backend_exit_is_reported_and_cleaned_without_owner_stop(self):
        result = self.run_store("post-start-backend-exit")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["failureReportedBeforeStop"], result)
        self.assertEqual(result["exitStatusBeforeStop"], 1, result)
        self.assertFalse(result["exitStopRequestedBeforeStop"], result)
        self.assertFalse(result["activeBeforeStop"], result)
        self.assertTrue(result["stopped"], result)

    def test_post_start_protocol_hold_is_reported_and_cleaned_without_owner_stop(self):
        result = self.run_store("post-start-protocol-hold")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["configurationChangedReported"], result)
        self.assertTrue(result["failureReportedBeforeStop"], result)
        self.assertEqual(result["exitStatusBeforeStop"], 1, result)
        self.assertFalse(result["exitStopRequestedBeforeStop"], result)
        self.assertFalse(result["activeBeforeStop"], result)
        self.assertTrue(result["stopped"], result)

    def test_permission_mutation_refusal_cannot_be_followed_by_input_in_the_same_generation(self):
        result = self.run_store("unsupported-permission")
        self.assertEqual(result["startError"], "", result)
        self.assertTrue(result["permissionRefused"], result)
        self.assertTrue(result["subsequentInputRefused"], result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertTrue(result["stopped"], result)


if __name__ == "__main__":
    unittest.main()
