"""Exercise actual owned-view mutation bodies against controlled, non-GUI native host seams.

These stand-ins do not establish AppKit event coverage or WebKit painting qualification.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedRendererNativeBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-native-boundary-"))
        print(f"Retained controlled native host fixture: {cls.build}", file=sys.stderr)
        fixture = ROOT / "scripts/tests/fixtures/managed_renderer_native_boundary.swift"
        common = ["swiftc", "-swift-version", "5", "-gnone", "-I", str(cls.build), "-L", str(cls.build)]
        for module, define, dependencies in [
            ("AppKit", "MOCK_APPKIT", []),
            ("WebKit", "MOCK_WEBKIT", ["AppKit"]),
            ("CmuxBrowser", "MOCK_BROWSER", ["AppKit", "WebKit"]),
        ]:
            command = [
                *common, "-emit-library", "-emit-module", "-module-name", module, "-D", define,
                *[f"-l{name}" for name in dependencies], str(fixture),
                "-o", str(cls.build / f"lib{module}.dylib"),
            ]
            cls.compile(command, module)
        names = [
            "Sources/Panels/AgentSessionManagedRendererReservation.swift",
            "Sources/Panels/AgentSessionManagedRendererController.swift",
            "Sources/Panels/AgentSessionWebView.swift",
            "Sources/Panels/AgentSessionWebHostView.swift",
            "Sources/Panels/AgentSessionWebHostGeometryState.swift",
            "scripts/tests/fixtures/managed_renderer_native_boundary.swift",
        ]
        sources = []
        for name in names:
            target = cls.build / Path(name).name
            shutil.copy2(ROOT / name, target)
            sources.append(str(target))
        cls.executable = cls.build / "NativeBoundaryFixture"
        cls.compile([
            *common, "-parse-as-library", "-module-name", "ManagedNativeBoundary",
            "-lAppKit", "-lWebKit", "-lCmuxBrowser", "-o", str(cls.executable), *sources,
        ], "fixture")

    @classmethod
    def compile(cls, command, name):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        log = cls.build / f"{name}-build.log"
        log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Controlled host source build failed; {log}\n"
                               + (result.stdout + result.stderr)[-10000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_deferred_scroll_revokes_a_frame_acquired_after_the_original_event(self):
        self.scenario("deferred-scroll")

    def test_host_opacity_aba_revokes_the_native_frame(self):
        self.scenario("host-opacity")

    def test_webview_opacity_aba_revokes_the_native_frame(self):
        self.scenario("view-opacity")

    def test_host_visibility_aba_revokes_the_native_frame(self):
        self.scenario("host-hidden")

    def test_webview_visibility_aba_revokes_the_native_frame(self):
        self.scenario("view-hidden")


if __name__ == "__main__":
    unittest.main()
