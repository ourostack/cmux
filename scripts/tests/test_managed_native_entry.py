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
        for name in ["AgentSessionPanel.swift", "AgentSessionWebRendererSession.swift"]:
            target = cls.build / name
            shutil.copy2(ROOT / "Sources/Panels" / name, target)
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


if __name__ == "__main__":
    unittest.main()
