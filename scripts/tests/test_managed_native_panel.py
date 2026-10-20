"""Run actual Panel/Session mutation bodies with a non-GUI coordinator stand-in."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedNativePanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-native-panel-"))
        print(f"Retained actual native panel fixture: {cls.build}", file=sys.stderr)
        sources = []
        for name in [
            "Sources/Panels/AgentSessionPanel.swift",
            "Sources/Panels/AgentSessionWebRendererSession.swift",
            "scripts/tests/fixtures/managed_native_panel.swift",
        ]:
            target = cls.build / Path(name).name
            shutil.copy2(ROOT / name, target)
            sources.append(str(target))
        cls.executable = cls.build / "NativePanelFixture"
        result = subprocess.run(
            ["swiftc", "-swift-version", "5", "-gnone", "-parse-as-library",
             *sources, "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=120,
        )
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Actual native panel source build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])

    def scenario(self, name):
        result = subprocess.run(
            [str(self.executable), name], capture_output=True, text=True, timeout=10,
        )
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_workspace_changes_revoke_before_mutating_native_panel_scope(self):
        self.scenario("workspace")

    def test_directory_changes_revoke_before_clearing_native_project_scope(self):
        self.scenario("directory")

    def test_provider_changes_revoke_before_changing_native_provider_scope(self):
        self.scenario("provider")

    def test_close_revokes_native_authority_before_closing_the_renderer(self):
        self.scenario("close")

    def test_noop_native_scope_updates_do_not_close_an_unchanged_panel(self):
        self.scenario("noop")


if __name__ == "__main__":
    unittest.main()
