"""Run actual coordinator event bodies with the native controller and non-GUI platform seams."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedRendererEventLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-renderer-events-"))
        print(f"Retained native event lifecycle fixture: {cls.build}", file=sys.stderr)
        coordinator = (ROOT / "Sources/Panels/AgentSessionWebRendererCoordinator.swift").read_text()
        fixture = (ROOT / "scripts/tests/fixtures/managed_renderer_event_lifecycle.swift").read_text()
        bodies = {
            "__EVENT_SINK__": "        processStore.eventSink = {"
                + coordinator.split("        processStore.eventSink = {", 1)[1]
                .split("        processStore.activeProviderSink", 1)[0],
            "__SEND_EVENT__": "    private func sendEvent("
                + coordinator.split("    private func sendEvent(", 1)[1]
                .split("    private func handleExternalLink(", 1)[0],
        }
        for key, body in bodies.items():
            marker = "// " + key
            if fixture.count(marker) != 1:
                raise RuntimeError(f"Expected one actual-source seam: {key}")
            fixture = fixture.replace(marker, body)
        generated = cls.build / "EventFixture.swift"
        generated.write_text(fixture)
        sources = [str(generated)]
        for name in ["AgentSessionManagedRendererReservation.swift", "AgentSessionManagedRendererController.swift"]:
            target = cls.build / name
            shutil.copy2(ROOT / "Sources/Panels" / name, target)
            sources.append(str(target))
        cls.executable = cls.build / "EventFixture"
        result = subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-gnone",
            *sources, "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=120)
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Native event source compilation failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_store_projection_revokes_the_write_frame_without_discarding_owned_editor_cleanup(self):
        self.scenario("store")

    def test_direct_native_event_revokes_the_write_frame_without_discarding_owned_editor_cleanup(self):
        self.scenario("direct")


if __name__ == "__main__":
    unittest.main()
