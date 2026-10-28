"""Compile actual native entry bodies against controlled non-GUI composition seams.

Store ownership/profile enforcement has its own actual-source subprocess tests.
These seams do not qualify AppKit delivery, WebKit readiness, or a provider.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedNativeEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-native-entry-"))
        print(f"Retained native entry body fixture: {cls.build}", file=sys.stderr)
        coordinator = (ROOT / "Sources/Panels/AgentSessionWebRendererCoordinator.swift").read_text()
        workspace = (ROOT / "Sources/Workspace.swift").read_text()
        launch = (ROOT / "Sources/Panels/AgentSessionManagedCopilotLaunch.swift").read_text()
        fixture = (ROOT / "scripts/tests/fixtures/managed_native_entry.swift").read_text()
        bodies = {
            "__ACTUAL_PANEL_CONSTRUCTION__": "        let agentPanel = AgentSessionPanel(" + workspace.split(
                "        let agentPanel = AgentSessionPanel(", 1
            )[1].split("        panels[agentPanel.id] = agentPanel", 1)[0],
            "__ACTUAL_SNAPSHOT_CONSTRUCTION__": "            agentSessionSnapshot = SessionAgentSessionPanelSnapshot(" + workspace.split(
                "            agentSessionSnapshot = SessionAgentSessionPanelSnapshot(", 1
            )[1].split("            projectSnapshot = nil", 1)[0],
            "__ACTUAL_SNAPSHOT_RESTORE__": workspace.split(
                "            guard let agentSession = snapshot.agentSession,", 1
            )[1].split("        case .project:", 1)[0],
            "__ACTUAL_CONTEXT_TAIL__": '            if let workingDirectory {\n                context["workingDirectory"]' + coordinator.split(
                '            if let workingDirectory {\n                context["workingDirectory"]', 1
            )[1].split('        case "app.pickFiles":', 1)[0],
            "__ACTUAL_MANUAL_PROVIDER_BRANCHES__": '        case "provider.select":' + coordinator.split(
                '        case "provider.select":', 1
            )[1].split('        case "provider.writeLine":', 1)[0],
            "__BIND_METHOD__": coordinator.split("    func bind(", 1)[1]
                .split("    /// Records the host", 1)[0],
            "__NATIVE_ENTRY_METHODS__": coordinator.split("    func prepareNativeCodingStart(", 1)[1]
                .split("    /// Native-only renderer custody.", 1)[0],
            "__WORKSPACE_ENTRY_METHODS__": workspace.split("    @discardableResult\n    func newManagedCopilotSessionSurface(", 1)[1]
                .split("    /// Binds composer command routing", 1)[0],
            "__CANONICAL_METHOD__": launch.split("    nonisolated static func canonicalPath(", 1)[1]
                .split("    func launchBackend()", 1)[0],
            "__CURRENT_DIRECTORY_WILL_SET__": workspace.split("    @Published var currentDirectory: String {", 1)[1]
                .split("        didSet {", 1)[0],
            "__REMOTE_WILL_SET__": workspace.split("    @Published var remoteConfiguration: WorkspaceRemoteConfiguration? {", 1)[1]
                .split("        didSet {", 1)[0],
            "__REMOTE_REPORT_PROPERTY__": workspace.split("    private(set) var remoteDirectoryReportPanelIds:", 1)[1]
                .split("    var endedPersistentRemotePTYAttachSurfaceIds:", 1)[0],
            "__CONTEXT_REQUEST_BODY__": coordinator.split('        case "app.context":', 1)[1]
                .split("            var context:", 1)[0],
            "__NAVIGATION_START_METHOD__": coordinator.split(
                "    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {", 1
            )[1].split("    func webViewWebContentProcessDidTerminate", 1)[0],
            "__PROCESS_TERMINATION_METHOD__": coordinator.split(
                "    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {", 1
            )[1].split("    func webView(\n", 1)[0],
        }
        bodies["__ACTUAL_SNAPSHOT_RESTORE__"] = (
            "            guard let agentSession = snapshot.agentSession," + bodies["__ACTUAL_SNAPSHOT_RESTORE__"]
        )
        bodies["__BIND_METHOD__"] = "    func bind(" + bodies["__BIND_METHOD__"]
        bodies["__NATIVE_ENTRY_METHODS__"] = "    func prepareNativeCodingStart(" + bodies["__NATIVE_ENTRY_METHODS__"]
        bodies["__WORKSPACE_ENTRY_METHODS__"] = "    func newManagedCopilotSessionSurface(" + bodies["__WORKSPACE_ENTRY_METHODS__"]
        bodies["__CANONICAL_METHOD__"] = "    nonisolated static func canonicalPath(" + bodies["__CANONICAL_METHOD__"]
        bodies["__REMOTE_REPORT_PROPERTY__"] = (
            "    private(set) var remoteDirectoryReportPanelIds:" + bodies["__REMOTE_REPORT_PROPERTY__"]
        )
        bodies["__NAVIGATION_START_METHOD__"] = (
            "    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {"
            + bodies["__NAVIGATION_START_METHOD__"]
        )
        bodies["__PROCESS_TERMINATION_METHOD__"] = (
            "    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {"
            + bodies["__PROCESS_TERMINATION_METHOD__"]
        )
        for key, body in bodies.items():
            marker = "// " + key
            if fixture.count(marker) != 1:
                raise RuntimeError(f"Expected exactly one controlled source-body seam: {key}")
            fixture = fixture.replace(marker, body)
        generated = cls.build / "NativeEntryFixture.swift"
        generated.write_text(fixture)
        sources = [str(generated)]
        for name in [
            "Panels/AgentSessionPanel.swift", "Panels/AgentSessionWebRendererSession.swift",
            "SessionAgentSessionPanelSnapshot.swift", "AgentSessionProvider.swift",
        ]:
            target = cls.build / Path(name).name
            shutil.copy2(ROOT / "Sources" / name, target)
            sources.append(str(target))
        cls.executable = cls.build / "NativeEntryFixture"
        result = subprocess.run(
            ["swiftc", "-swift-version", "5", "-gnone", "-parse-as-library",
             *sources, "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=120,
        )
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Native entry body build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-14000:])

    def scenario(self, name):
        result = subprocess.run(
            [str(self.executable), name], capture_output=True, text=True, timeout=10,
        )
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_only_a_fresh_native_action_can_schedule_either_renderer(self):
        for scenario in ["react", "solid", "ordinary"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_native_start_waits_for_both_context_and_navigation_without_replay(self):
        for scenario in ["context-first", "navigation-first", "repeat"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_current_native_object_and_scope_changes_revoke_pending_authority(self):
        for scenario in [
            "other-workspace", "missing-panel", "close", "workspace-id", "directory",
            "provider", "project-root", "remote-transition", "navigation-reload", "web-process-exit",
            "bind-panel", "bind-workspace", "bind-renderer", "bind-directory", "bind-provider",
            "replacement-workspace",
        ]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_nonlocal_or_noncurrent_projects_are_rejected_before_panel_creation(self):
        for scenario in ["remote", "remote-provenance", "cloud", "remote-report", "retired", "not-current", "file-directory"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_canonical_native_project_is_shared_by_panel_owner_and_launch(self):
        self.scenario("canonical-directory")

    def test_late_native_completion_cannot_clear_a_new_manual_start_reservation(self):
        self.scenario("late-task")

    def test_native_revocation_does_not_clear_an_ordinary_manual_start_reservation(self):
        self.scenario("manual-reservation")

    def test_native_failure_revokes_without_a_context_retry_or_false_success(self):
        self.scenario("start-failed")

    def test_untrusted_shell_context_cannot_consume_the_pending_native_start(self):
        self.scenario("untrusted-shell")

    def test_owner_loss_during_fresh_panel_creation_closes_only_that_new_panel(self):
        self.scenario("creation-owner-lost")

    def test_remote_provenance_aba_permanently_revokes_an_issued_native_owner(self):
        self.scenario("remote-provenance-aba")

    def test_codex_native_entry_binds_the_requested_provider_and_both_renderers(self):
        for scenario in ["react", "solid", "canonical-directory"]:
            with self.subTest(scenario=scenario):
                self.scenario("codex-" + scenario)

    def test_codex_context_navigation_order_and_failed_start_are_not_replayed(self):
        for scenario in ["context-first", "navigation-first", "repeat", "start-failed", "untrusted-shell"]:
            with self.subTest(scenario=scenario):
                self.scenario("codex-" + scenario)

    def test_codex_owner_invalidation_cannot_launch_or_bind_a_renderer(self):
        for scenario in [
            "other-workspace", "replacement-workspace", "missing-panel", "close", "workspace-id", "directory",
            "provider", "project-root", "remote-transition", "remote-provenance-aba", "navigation-reload",
            "web-process-exit", "bind-panel", "bind-workspace", "bind-renderer", "bind-directory", "bind-provider",
            "late-task", "creation-owner-lost",
        ]:
            with self.subTest(scenario=scenario):
                self.scenario("codex-" + scenario)

    def test_codex_nonlocal_projects_are_refused_before_creation(self):
        for scenario in ["remote", "remote-provenance", "cloud", "remote-report", "retired", "not-current", "file-directory"]:
            with self.subTest(scenario=scenario):
                self.scenario("codex-" + scenario)

    def test_managed_intent_stays_native_after_owner_revocation(self):
        for provider in ["copilot", "codex"]:
            with self.subTest(provider=provider):
                self.scenario(provider + "-retained-intent" if provider == "codex" else "retained-intent")

    def test_managed_panels_refuse_browser_selection_and_start_after_revocation(self):
        for scenario in ["managed-manual-refusal", "codex-managed-manual-refusal", "ordinary-manual-start"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_saved_managed_intent_restores_held_without_minting_an_owner(self):
        for scenario in [
            "snapshot-intent", "codex-snapshot-intent", "restore-intent", "codex-restore-intent", "legacy-restore",
        ]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_real_provider_enum_refuses_unsupported_native_profiles_before_issuing_an_owner(self):
        self.scenario("unsupported-native-provider")


if __name__ == "__main__":
    unittest.main()
