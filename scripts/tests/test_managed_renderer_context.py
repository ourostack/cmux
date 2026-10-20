"""Run the actual coordinator context guard with non-GUI native property seams."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedRendererContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-renderer-context-"))
        print(f"Retained native context fixture: {cls.build}", file=sys.stderr)
        coordinator = (ROOT / "Sources/Panels/AgentSessionWebRendererCoordinator.swift").read_text()
        fixture = (ROOT / "scripts/tests/fixtures/managed_renderer_context.swift").read_text()
        bodies = {
            "__CONTEXT_METHOD__": "    private func currentManagedRendererContext("
                + coordinator.split("    private func currentManagedRendererContext(", 1)[1]
                .split("    private func performManagedRendererOperation(", 1)[0],
            "__TRUST_METHODS__": "    nonisolated static func isTrustedShellURL("
                + coordinator.split("    nonisolated static func isTrustedShellURL(", 1)[1]
                .split("    private func handle(", 1)[0],
            "__RESPONDER_METHOD__": "    private static func responderChainContains("
                + coordinator.split("    private static func responderChainContains(", 1)[1]
                .split("\n}\n", 1)[0],
        }
        for key, body in bodies.items():
            marker = "// " + key
            if fixture.count(marker) != 1:
                raise RuntimeError(f"Expected one actual-source seam: {key}")
            fixture = fixture.replace(marker, body)
        generated = cls.build / "ContextFixture.swift"
        generated.write_text(fixture)
        sources = [str(generated)]
        for name in ["AgentSessionManagedRendererReservation.swift", "AgentSessionManagedRendererController.swift"]:
            target = cls.build / name
            shutil.copy2(ROOT / "Sources/Panels" / name, target)
            sources.append(str(target))
        cls.executable = cls.build / "ContextFixture"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-swift-version", "5", "-gnone",
             *sources, "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=120,
        )
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Native context source build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_visible_unfocused_native_target_can_capture_without_focus_theft(self):
        self.scenario("unfocused")

    def test_human_focused_panel_or_web_content_cannot_supply_automatic_evidence(self):
        for name in ["panel-focused", "web-focused", "web-descendant-focused", "no-responder"]:
            with self.subTest(name=name):
                self.scenario(name)

    def test_unfocused_capture_preserves_every_other_native_admission_gate(self):
        for name in [
            "not-owned", "foreign-owner", "closed", "navigation", "paint", "panel", "workspace",
            "renderer", "directory", "no-host", "no-webview", "no-window", "foreign-window",
            "foreign-parent", "inactive", "not-key", "invisible", "miniaturized", "occluded",
            "hidden-host-ancestor", "hidden-view-ancestor", "empty-host", "empty-view", "loading",
            "untrusted-url", "missing-trust", "ancestor-opacity", "ancestor-hidden", "nonfinite",
        ]:
            with self.subTest(name=name):
                self.scenario(name)

    def test_unrelated_responder_and_geometry_changes_revoke_an_existing_native_frame(self):
        for name in ["responder-changed", "geometry-changed"]:
            with self.subTest(name=name):
                self.scenario(name)


if __name__ == "__main__":
    unittest.main()
