"""Run the actual ProcessStore with owned controlled children, never providers or a GUI."""

import json
import hashlib
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
            "Sources/Panels/AgentSessionManagedNativeOwner.swift",
            "Sources/Panels/AgentSessionManagedProviderAdapter.swift",
            "Sources/Panels/AgentSessionManagedCodexLaunch.swift",
            "Sources/Panels/AgentSessionManagedJSON.swift",
            "Sources/Panels/CodexManagedSession.swift", "Sources/Panels/CodexManagedStartup.swift",
            "Sources/Panels/CodexManagedStreamDecoder.swift", "Sources/Panels/CodexManagedShellInventory.swift",
            "Sources/Panels/CodexManagedTurnLedger.swift",
            "Sources/Panels/AgentSessionManagedRendererController.swift",
            "Sources/Panels/AgentSessionManagedRendererReservation.swift",
            "Sources/Panels/AgentSessionManagedCommandService.swift", "Sources/Panels/CopilotManagedSession.swift",
            "Sources/Panels/CopilotManagedConfiguration.swift", "Sources/Panels/CopilotManagedEventMetadata.swift",
            "Sources/Panels/CopilotManagedTurnLedger.swift",
            "Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayCommandPolicy.swift",
            "Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayRoutingSchema.swift",
            "Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/RemoteRelayAuthorizationPolicy.swift",
            "scripts/tests/fixtures/managed_session_lifetime.swift",
            "scripts/tests/fixtures/managed_command_service.swift",
            "scripts/tests/fixtures/managed_copilot_startup.swift",
            "scripts/tests/fixtures/managed_process_store.swift",
            "scripts/tests/fixtures/managed_shepherd_boundary.swift",
        ]
        boundary = "Sources/Panels/AgentSessionManagedShepherdBoundary.swift"
        if (ROOT / boundary).exists():
            names.append(boundary)
        for name in names:
            shutil.copy2(ROOT / name, source)
        routing = (ROOT / "scripts/tests/fixtures/managed_shepherd_routing.swift").read_text()
        shepherd = (ROOT / "Sources/TerminalController+Shepherd.swift").read_text()
        socket = (ROOT / "Sources/TerminalController+ControlSocketAsync.swift").read_text()
        capabilities = (ROOT / "Sources/TerminalController+Capabilities.swift").read_text()
        terminal = (ROOT / "Sources/TerminalController.swift").read_text()
        sections = {
            "__SHEPHERD_ROUTE__": shepherd.split("extension TerminalController {", 1)[1]
                .split("    func makeShepherdControlBoundary(", 1)[0],
            "__MANAGED_FACTORY__": "    func makeManagedShepherdControlBoundary("
                + shepherd.split("    func makeManagedShepherdControlBoundary(", 1)[1]
                .split("\n}\n\n@MainActor", 1)[0],
            "__SOCKET_ROUTE__": "    private nonisolated func processV2CommandUsingSocketExecutionPolicyAsync("
                + socket.split("    private nonisolated func processV2CommandUsingSocketExecutionPolicyAsync(", 1)[1]
                .split("        let relayAuthorization =", 1)[0]
                + '        return "relay_authorization_reached"\n    }\n',
            "__CAPABILITIES__": "    nonisolated func v2CapabilitiesWithBrowserDesignMode("
                + capabilities.split("    nonisolated func v2CapabilitiesWithBrowserDesignMode(", 1)[1]
                .split("    private nonisolated func v2Capabilities(", 1)[0],
            "__SYNC_ROUTE__": "    func v2MainActorResponse("
                + terminal.split("    func v2MainActorResponse(", 1)[1]
                .split("        v2RefreshKnownRefs()", 1)[0]
                + '        return .callResult(.err(code: "legacy_route", message: "", data: nil))\n    }\n',
        }
        for marker, body in sections.items():
            routing = routing.replace("// " + marker, body)
        coordinator = (ROOT / "Sources/Panels/AgentSessionWebRendererCoordinator.swift").read_text()
        session = (ROOT / "Sources/Panels/AgentSessionWebRendererSession.swift").read_text()
        target_bodies = {
            "__MANAGED_RENDERER__": "    func managedRenderer("
                + coordinator.split("    func managedRenderer(", 1)[1]
                .split("    private func installManagedRendererObservation(", 1)[0],
            "__COORDINATOR_TARGET__": "    func managedShepherdTarget("
                + coordinator.split("    func managedShepherdTarget(", 1)[1]
                .split("    private func installManagedRendererObservation(", 1)[0],
            "__SESSION_TARGET__": "    func managedShepherdTarget("
                + session.split("    func managedShepherdTarget(", 1)[1]
                .split("    func focus(", 1)[0],
        }
        # The accessor is inserted after managedRenderer; do not copy it twice.
        target_bodies["__MANAGED_RENDERER__"] = target_bodies["__MANAGED_RENDERER__"].split(
            "    func managedShepherdTarget(", 1
        )[0]
        for marker, body in target_bodies.items():
            routing = routing.replace("// " + marker, body)
        (source / "managed_shepherd_routing.swift").write_text(routing)
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

    def test_native_owner_binding_rejects_foreign_provider_before_backend_identity(self):
        result = self.run_store("native-provider-binding")
        self.assertEqual(result["events"], 0, result)
        for provider in ("copilot", "codex", "claude"):
            with self.subTest(provider=provider):
                check = result["providers"][provider]
                self.assertTrue(check["identityMissing"], result)
                self.assertEqual(check["accepted"], provider == "copilot", result)
                self.assertEqual(check["ownerCurrent"], provider == "copilot", result)

    def test_native_owner_binding_requires_exact_scope_before_backend_identity(self):
        result = self.run_store("native-scope-binding")
        self.assertEqual(result["events"], 0, result)
        for candidate, check in result["providers"].items():
            with self.subTest(candidate=candidate):
                self.assertTrue(check["identityMissing"], result)
                self.assertEqual(check["accepted"], candidate == "exact", result)
                self.assertEqual(check["ownerCurrent"], candidate == "exact", result)

    def test_common_native_owner_binds_only_its_declared_provider_without_qualifying_any_profile(self):
        result = self.run_store("native-provider-owner-matrix")
        self.assertEqual(result["events"], 0, result)
        self.assertFalse(result["storeActive"], result)
        self.assertEqual(len(result["providers"]), 9, result)
        for pair, check in result["providers"].items():
            with self.subTest(pair=pair):
                owner, lifetime = pair.split("-")
                self.assertTrue(check["identityMissing"], result)
                for field in ("accepted", "ownerCurrent", "authorizes"):
                    self.assertEqual(check[field], owner == lifetime, result)
                self.assertFalse(check["reactQualified"], result)
                self.assertFalse(check["solidQualified"], result)

    def test_shared_progress_rejects_foreign_provider_with_all_other_ids_identical(self):
        result = self.run_store("native-progress-provider-binding")
        self.assertEqual(result["events"], 0, result)
        self.assertFalse(result["storeActive"], result)
        self.assertEqual(len(result["checks"]), 24, result)
        for pair, accepted in result["checks"].items():
            with self.subTest(pair=pair):
                if pair.startswith(("wrong-input-", "write-regression-", "ack-regression-")):
                    self.assertFalse(accepted, result)
                else:
                    expected, observed = pair.split("-")
                    self.assertEqual(accepted, expected == observed, result)

    def test_managed_socket_methods_bypass_relay_and_keep_the_classic_namespace_distinct(self):
        result = self.run_store("managed-socket-route")
        self.assertEqual(result["recognized"], [True, True, True, True, False, False], result)
        self.assertEqual(result["managed"], ["invalid_params", "invalid_params", "invalid_params"], result)
        self.assertEqual(result["classic"], "classic_boundary", result)
        self.assertEqual(result["other"], "relay_authorization_reached", result)

    def test_managed_socket_rejects_original_remote_provenance_before_any_native_boundary_lookup(self):
        result = self.run_store("managed-socket-provenance")
        self.assertEqual(result["errors"], ["access_denied"] * 12, result)
        self.assertEqual(result["managedLookups"], 0, result)
        self.assertEqual(result["classicLookups"], 0, result)

    def test_managed_local_discovery_is_explicitly_unqualified_and_remote_discovery_does_not_advertise_it(self):
        result = self.run_store("managed-socket-capabilities")
        self.assertTrue(result["localManagedMethods"], result)
        self.assertEqual(result["managed"], {
            "protocol_version": 1, "state": "unqualified", "providers": [], "profiles": [],
            "qualification_reason": "managed_native_runtime_unqualified",
        }, result)
        self.assertFalse(result["remoteManagedMethods"], result)
        self.assertFalse(result["remoteManagedCapability"], result)
        self.assertEqual(result["classicState"], "unqualified", result)
        self.assertEqual(result["classicReason"], "claude_native_input_attribution_unavailable", result)

    def test_synchronous_managed_calls_cannot_fall_through_into_legacy_input(self):
        result = self.run_store("managed-socket-sync")
        self.assertEqual(result["errors"], ["access_denied"] * 3, result)
        self.assertEqual(result["managedLookups"], 0, result)

    def test_native_target_comes_from_current_owned_coordinator_store_and_session_not_ui_claims(self):
        result = self.run_store("native-coding-supervisor-rpc-target-accessor")
        self.assertTrue(result["exactTarget"], result)
        self.assertEqual(result["refused"], [True] * 9, result)
        self.assertEqual(result["captures"], 0, result)
        self.assertEqual(result["insertions"], 0, result)
        self.assertTrue(result["stopped"], result)

    def test_actual_native_factory_resolves_only_the_exact_live_local_panel_and_retains_no_owner(self):
        result = self.run_store("native-coding-supervisor-rpc-target-factory")
        self.assertTrue(result["inspectedExactTarget"], result)
        self.assertEqual(result["refused"], ["target_unavailable"] * 8, result)
        self.assertEqual(result["captures"], 1, result)
        self.assertEqual(result["insertions"], 0, result)
        self.assertTrue(result["stopped"], result)

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

    def test_native_coding_projection_exposes_attributed_reply_and_actual_command_outcomes(self):
        result = self.run_store("native-coding-input")
        self.assertEqual(result["startError"], "", result)
        self.assertEqual(result["inputError"], "", result)
        self.assertEqual(result["commandExecutions"], "read\nedit\nvalidate\n", result)
        events = result["nativeEvents"]
        output = [event for event in events if event["type"] == "provider.output"
                  and event["stream"] == "stdout"]
        self.assertEqual([event["text"] for event in output], ["Done\n\n"], result)
        activity = [event for event in events if event["type"] == "provider.activity"]
        self.assertEqual([event["status"] for event in activity],
                         ["inProgress", "completed"] * 3, result)
        self.assertEqual([event["activityId"] for event in activity],
                         ["call-0", "call-0", "call-1", "call-1", "call-2", "call-2"], result)
        self.assertTrue(all(event["kind"] == "command" for event in activity), result)
        self.assertEqual([event.get("outputDelta", "") for event in activity
                          if event["status"] == "completed"], ["before\n", "", "validated\n"], result)
        completion = [event for event in events if event["type"] == "provider.turnComplete"]
        self.assertEqual(len(completion), 1, result)
        self.assertTrue(all(event["sessionId"] == result["sessionID"] and event["providerId"] == "copilot"
                            for event in [*output, *activity, *completion]), result)
        self.assertLess(events.index(activity[-1]), events.index(output[0]), result)
        self.assertLess(events.index(output[0]), events.index(completion[0]), result)
        self.assertTrue(result["workReadbacksObserved"], result)
        self.assertTrue(result["stopped"], result)

    def test_reentrant_projection_close_stops_native_work_and_protocol_writes(self):
        for moment, executions, responses in [
            ("start", "", 0), ("completion", "read\n", 0),
            ("assistant", "read\nedit\nvalidate\n", 3),
        ]:
            with self.subTest(moment=moment):
                result = self.run_store(f"native-coding-projection-close-{moment}")
                self.assertTrue(result["projectionClosed"], result)
                self.assertTrue(result["stopped"], result)
                self.assertEqual(result["commandExecutions"], executions, result)
                self.assertEqual(result["peerTrace"].splitlines().count("session.tools.handlePendingToolCall"),
                                 responses, result)
                self.assertFalse(result["workReadbacksObserved"], result)
                self.assertFalse(any(event["type"] == "provider.turnComplete"
                                     for event in result["nativeEvents"]), result)

    def test_supervisor_input_uses_exact_bound_literal_distinct_origin_and_provider_ack(self):
        result = self.run_store("native-coding-supervisor")
        self.assertTrue(result["registered"], result)
        self.assertEqual(result["firstOrigin"], "owner", result)
        self.assertEqual(result["lastOrigin"], "supervisor", result)
        self.assertTrue(result["inputIDMatches"], result)
        self.assertTrue(result["editorInserted"], result)
        self.assertTrue(result["backendWriteAdmitted"], result)
        self.assertEqual(result["providerInputID"], "server-input-two", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertEqual(result["commandExecutions"], "read\nedit\nvalidate\n", result)
        self.assertTrue(result["identityMatches"], result)
        self.assertTrue(result["stopped"], result)

    def test_managed_rpc_binds_native_identity_raw_painted_screen_and_retains_exact_ack_after_close(self):
        result = self.run_store("native-coding-supervisor-rpc-success")
        inspection = result["inspection"]
        self.assertEqual(inspection["protocol_version"], 1, result)
        self.assertEqual(inspection["host_instance"], result["identityHost"], result)
        self.assertEqual(inspection["identity"]["kind"], "agent_session", result)
        self.assertEqual(inspection.get("cwd"), os.path.realpath(result["directory"]), result)
        self.assertNotIn("tty", inspection["identity"], result)
        self.assertEqual(inspection["screen"], "Paint-bound native output", result)
        self.assertEqual(inspection["screen_fingerprint"],
                         hashlib.sha256(b"Paint-bound native output").hexdigest(), result)
        self.assertTrue(result["registeredBeforeInsertion"], result)
        self.assertEqual(result["first"]["state"], "accepted", result)
        for receipt in [result["first"], result["replay"], result["final"]]:
            self.assertEqual(receipt["state"], "accepted", result)
            self.assertTrue(receipt["editor_inserted"], result)
            self.assertTrue(receipt["backend_write_admitted"], result)
            self.assertTrue(receipt["provider_acknowledged"], result)
            self.assertEqual(receipt["provider_input_id"], "server-input-two", result)
            self.assertNotIn("paste_admitted", receipt, result)
            self.assertNotIn("submit_admitted", receipt, result)
        self.assertEqual(result["conflict"]["error"], "request_conflict", result)
        self.assertEqual(result["insertions"], 1, result)
        self.assertEqual(result["consumes"], 1, result)
        self.assertEqual(result["editor"], "", result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertFalse(result["storeProgressAfterClose"], result)
        self.assertTrue(result["stopped"], result)

    def test_managed_rpc_refuses_unverified_peer_and_remote_envelope_before_any_renderer_read(self):
        result = self.run_store("native-coding-supervisor-rpc-provenance")
        self.assertEqual(result["rejected"], ["access_denied"] * 4, result)
        self.assertEqual(result["captures"], 0, result)
        self.assertEqual(result["insertions"], 0, result)
        self.assertEqual(result["sendCount"], 1, result)
        self.assertTrue(result["stopped"], result)

    def test_managed_rpc_strict_parameters_do_not_alias_classic_methods_or_caller_authority(self):
        result = self.run_store("native-coding-supervisor-rpc-parameters")
        self.assertEqual(result["rejected"],
                         ["invalid_params"] * 3 + ["method_not_found", "invalid_params"], result)
        self.assertEqual(result["captures"], 0, result)
        self.assertEqual(result["insertions"], 0, result)
        self.assertEqual(result["sendCount"], 1, result)

    def test_managed_rpc_uncertain_editor_effect_never_becomes_not_sent_or_retried(self):
        for suffix in ["nil-insert", "throw-insert", "cancel"]:
            with self.subTest(suffix=suffix):
                result = self.run_store("native-coding-supervisor-rpc-" + suffix)
                for receipt in [result["first"], result["replay"], result["final"]]:
                    self.assertEqual(receipt["state"], "unknown", result)
                    self.assertFalse(receipt["backend_write_admitted"], result)
                    self.assertFalse(receipt["provider_acknowledged"], result)
                self.assertTrue(result["registeredBeforeInsertion"], result)
                self.assertEqual(result["insertions"], 1, result)
                self.assertEqual(result["editor"], "Continue authorized coding.", result)
                self.assertEqual(result["consumes"], 0, result)
                self.assertEqual(result["sendCount"], 1, result)
                self.assertTrue(result["stopped"], result)

    def test_managed_rpc_late_ack_reconciles_same_receipt_without_retry_and_only_then_cleans_editor(self):
        result = self.run_store("native-coding-supervisor-rpc-late-ack")
        self.assertEqual(result["first"]["state"], "unknown", result)
        self.assertEqual(result["final"]["state"], "accepted", result)
        self.assertTrue(result["final"]["provider_acknowledged"], result)
        self.assertEqual(result["final"]["provider_input_id"], "server-input-two", result)
        self.assertEqual(result["insertions"], 1, result)
        self.assertEqual(result["consumes"], 1, result)
        self.assertEqual(result["editor"], "", result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertTrue(result["stopped"], result)

    def test_managed_rpc_complete_bytes_without_ack_retains_unknown_after_owner_release_and_never_cleans(self):
        result = self.run_store("native-coding-supervisor-rpc-missing-ack")
        self.assertEqual(result["first"]["state"], "unknown", result)
        self.assertEqual(result["final"]["state"], "unknown", result)
        self.assertTrue(result["final"]["editor_inserted"], result)
        self.assertTrue(result["final"]["backend_write_admitted"], result)
        self.assertFalse(result["final"]["provider_acknowledged"], result)
        self.assertEqual(result["consumes"], 0, result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertFalse(result["storeProgressAfterClose"], result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_receipt_progress_is_exact_monotonic_and_survives_owner_release(self):
        result = self.run_store("native-coding-supervisor")
        self.assertEqual(result["receiptStages"], ["registration", "bytes", "ack"], result)
        self.assertTrue(result["receiptScopeMatches"], result)
        self.assertTrue(result["receiptPublishedWhileOwned"], result)
        self.assertFalse(result["receiptLookupAfterClose"], result)
        self.assertTrue(result["retainedReceiptHasBytes"], result)
        self.assertEqual(result["retainedReceiptProviderInputID"], "server-input-two", result)
        self.assertEqual(result["retainedReceiptFailure"], "", result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_receipt_failure_is_published_before_failed_owner_disappears(self):
        for suffix, stages, has_bytes, failure in [
            ("revoke-before-byte", ["registration", "failure"], False, "writeUnavailable"),
            ("missing-ack", ["registration", "bytes", "failure"], True, "responseTimeout"),
            ("backpressure", ["registration", "failure"], False, "writeUnavailable"),
        ]:
            with self.subTest(suffix=suffix):
                result = self.run_store("native-coding-supervisor-" + suffix)
                self.assertEqual(result["receiptStages"], stages, result)
                self.assertTrue(result["receiptScopeMatches"], result)
                self.assertTrue(result["receiptPublishedWhileOwned"], result)
                self.assertFalse(result["receiptLookupAfterClose"], result)
                self.assertEqual(result["retainedReceiptHasBytes"], has_bytes, result)
                self.assertEqual(result["retainedReceiptProviderInputID"], "", result)
                self.assertEqual(result["retainedReceiptFailure"], failure, result)
                self.assertTrue(result["stopped"], result)

    def test_supervisor_receipt_callback_close_cannot_resurrect_transport_or_emit_later_work(self):
        for moment, stages, sends, has_bytes, ack in [
            ("registration", ["registration", "failure"], [1], False, ""),
            ("bytes", ["registration", "bytes", "failure"], [1, 2], True, ""),
            ("ack", ["registration", "bytes", "ack"], [2], True, "server-input-two"),
        ]:
            with self.subTest(moment=moment):
                result = self.run_store("native-coding-supervisor-close-" + moment)
                self.assertTrue(result["receiptCloseRequested"], result)
                self.assertEqual(result["receiptStages"], stages, result)
                self.assertTrue(result["receiptScopeMatches"], result)
                self.assertTrue(result["receiptPublishedWhileOwned"], result)
                self.assertFalse(result["receiptLookupAfterClose"], result)
                self.assertEqual(result["retainedReceiptHasBytes"], has_bytes, result)
                self.assertEqual(result["retainedReceiptProviderInputID"], ack, result)
                self.assertIn(result["sendCount"], sends, result)
                self.assertFalse(result["workEvidence"], result)
                self.assertTrue(result["stopped"], result)

    def test_supervisor_late_exact_ack_updates_receipt_without_a_second_input_write(self):
        result = self.run_store("native-coding-supervisor-late-ack")
        self.assertEqual(result["receiptStages"], ["registration", "bytes", "ack"], result)
        self.assertEqual(result["retainedReceiptProviderInputID"], "server-input-two", result)
        self.assertTrue(result["retainedReceiptHasBytes"], result)
        self.assertEqual(result["retainedReceiptFailure"], "", result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertTrue(result["receiptScopeMatches"], result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_input_requires_complete_work_exact_native_custody_and_unexpired_editor_evidence(self):
        for suffix, sends in [("unready", 0), ("foreign-owner", 1), ("foreign-store", 1), ("expired", 1)]:
            with self.subTest(suffix=suffix):
                result = self.run_store(f"native-coding-supervisor-{suffix}")
                self.assertFalse(result["registered"], result)
                self.assertFalse(result["hasProgress"], result)
                self.assertEqual(result["editorInsertionCount"], 1, result)
                self.assertEqual(result["sendCount"], sends, result)
                self.assertTrue(result["stopped"], result)

    def test_supervisor_input_revalidates_before_first_actual_adapter_pipe_byte(self):
        result = self.run_store("native-coding-supervisor-revoke-before-byte")
        self.assertTrue(result["registered"], result)
        self.assertFalse(result["backendWriteAdmitted"], result)
        self.assertEqual(result["providerInputID"], "", result)
        self.assertEqual(result["failureReason"], "writeUnavailable", result)
        self.assertEqual(result["sendCount"], 1, result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_input_cannot_turn_byte_admission_without_ack_into_accepted_delivery(self):
        result = self.run_store("native-coding-supervisor-missing-ack")
        self.assertTrue(result["registered"], result)
        self.assertTrue(result["backendWriteAdmitted"], result)
        self.assertEqual(result["providerInputID"], "", result)
        self.assertEqual(result["failureReason"], "responseTimeout", result)
        self.assertFalse(result["workEvidence"], result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_input_duplicate_native_uuid_cannot_enqueue_a_second_write(self):
        result = self.run_store("native-coding-supervisor-duplicate")
        self.assertTrue(result["registered"], result)
        self.assertFalse(result["duplicateRegistered"], result)
        self.assertEqual(result["providerInputID"], "server-input-two", result)
        self.assertEqual(result["sendCount"], 2, result)
        self.assertTrue(result["stopped"], result)

    def test_supervisor_input_provider_activity_after_a_partial_frame_stops_the_next_adapter_syscall(self):
        result = self.run_store("native-coding-supervisor-backpressure")
        self.assertTrue(result["registered"], result)
        self.assertTrue(result["partialChunkObserved"], result)
        self.assertFalse(result["backendWriteAdmitted"], result)
        self.assertEqual(result["providerInputID"], "", result)
        self.assertEqual(result["failureReason"], "writeUnavailable", result)
        self.assertEqual(result["sendCount"], 1, result)
        self.assertFalse(result["workEvidence"], result)
        self.assertTrue(result["stopped"], result)

    def test_production_native_owner_requires_an_immutable_qualified_profile_before_launch(self):
        for renderer in ["react", "solid"]:
            with self.subTest(renderer=renderer):
                result = self.run_store("native-coding-production-" + renderer)
                self.assertEqual(result["startError"], "nativeProfileUnqualified", result)
                self.assertFalse(result["activeAfterAttempt"], result)
                self.assertFalse(result["peerStarted"], result)
                self.assertFalse(result["wireTraceExists"], result)
                self.assertTrue(result["failureReported"], result)
                self.assertFalse(result["productionStartedEvent"], result)
                self.assertEqual(result["fixtureRetryError"], "", result)
                self.assertTrue(result["fixtureRetryStarted"], result)
                self.assertTrue(result["stopped"], result)

    def test_prepared_production_native_launch_cannot_bypass_the_profile_gate(self):
        for renderer in ["react", "solid"]:
            with self.subTest(renderer=renderer):
                result = self.run_store("native-coding-production-direct-" + renderer)
                self.assertEqual(result["startError"], "nativeProfileUnqualified", result)
                self.assertRegex(result["executableSHA256"], r"^[0-9a-f]{64}$", result)
                self.assertRegex(result["profileSHA256"], r"^[0-9a-f]{64}$", result)
                self.assertFalse(result["peerStarted"], result)
                self.assertFalse(result["wireTraceExists"], result)
                self.assertEqual(result["fixtureRetryError"], "", result)
                self.assertTrue(result["fixtureRetryStarted"], result)
                self.assertTrue(result["stopped"], result)

    def test_renderer_owner_checks_require_this_stores_current_running_native_owner(self):
        result = self.run_store("native-coding-owner-check")
        self.assertTrue(result["nativeOwnerAvailable"], result)
        self.assertEqual(result["startError"], "", result)
        self.assertFalse(result["ownerAcceptedBeforeStart"], result)
        self.assertTrue(result["ownerAcceptedWhileRunning"], result)
        self.assertFalse(result["foreignStoreAcceptedOwner"], result)
        self.assertFalse(result["ownerAcceptedWhileClosing"], result)
        self.assertFalse(result["ownerAcceptedAfterClose"], result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertEqual(result["projectContents"], "before\n", result)
        self.assertTrue(result["stopped"], result)

    def test_renderer_owner_check_rejects_synchronous_close_inside_owner_callback(self):
        result = self.run_store("native-coding-owner-check-reentrant")
        self.assertEqual(result["startError"], "", result)
        self.assertFalse(result["ownerAcceptedWhileRunning"], result)
        self.assertFalse(result["ownerAcceptedWhileClosing"], result)
        self.assertFalse(result["ownerAcceptedAfterClose"], result)
        self.assertFalse(result["wireSendObserved"], result)
        self.assertEqual(result["projectContents"], "before\n", result)
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

    def test_unknown_cleanup_survives_store_release_and_cannot_be_evaded_with_a_fresh_store(self):
        result = self.run_store("host-held-retention")
        self.assertEqual(result["originalStartError"], "", result)
        self.assertTrue(result["originalCleanupUnverified"], result)
        self.assertTrue(result["heldStoreRetained"], result)
        self.assertEqual(result["freshStartError"], "managedCleanupUnverified", result)
        self.assertFalse(result["freshPeerStarted"], result)
        self.assertFalse(result["freshWireSendObserved"], result)
        self.assertTrue(result["fixtureBackendsAbsent"], result)

    def test_verified_cleanup_releases_the_host_owned_store_reference(self):
        result = self.run_store("host-verified-release")
        self.assertEqual(result["originalStartError"], "", result)
        self.assertTrue(result["originalStopped"], result)
        self.assertFalse(result["storeRetainedAfterVerifiedCleanup"], result)

    def test_healthy_stores_can_coexist_and_only_unsettled_cleanup_fences_a_fresh_launch(self):
        result = self.run_store("host-healthy-concurrency")
        self.assertTrue(result["twoHealthyStoresActive"], result)
        self.assertEqual(result["pendingCleanupStartError"], "managedCleanupUnverified", result)
        self.assertFalse(result["pendingCleanupPeerStarted"], result)
        self.assertTrue(result["freshStartAfterVerifiedCleanup"], result)
        self.assertTrue(result["allStopped"], result)

    def test_owner_authorization_cannot_make_the_host_cleanup_fence_stale(self):
        result = self.run_store("host-fence-after-owner-callback")
        self.assertEqual(result["startError"], "managedCleanupUnverified", result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["controlledChildrenAbsent"], result)

    def test_cleanup_becoming_unverified_during_preparation_prevents_backend_launch(self):
        result = self.run_store("host-fence-before-backend-launch")
        self.assertEqual(result["startError"], "managedCleanupUnverified", result)
        self.assertFalse(result["peerStarted"], result)
        self.assertTrue(result["controlledChildrenAbsent"], result)

    def test_a_held_kept_command_survives_provider_shutdown_and_fences_a_fresh_store(self):
        result = self.run_store("host-command-held")
        self.assertEqual(result["originalStartError"], "", result)
        self.assertTrue(result["commandHeldUncertain"], result)
        self.assertTrue(result["originalCleanupUnverified"], result)
        self.assertTrue(result["heldStoreRetained"], result)
        self.assertEqual(result["freshStartError"], "managedCleanupUnverified", result)
        self.assertFalse(result["freshPeerStarted"], result)
        self.assertTrue(result["fixtureBackendsAbsent"], result)

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
