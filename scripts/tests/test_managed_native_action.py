"""Exercise actual AppDelegate managed actions against non-GUI composition seams.

This does not launch AppKit, WebKit, a coding provider, or a qualified profile.
Actual Workspace/Session/Store behavior has separate exact-source tests.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedNativeActionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-native-action-"))
        print(f"Retained native action source fixture: {cls.build}", file=sys.stderr)
        source = (ROOT / "Sources/AppDelegate.swift").read_text()
        start = "    @objc func openDebugManagedCopilotReact("
        end = "    private func openDebugAgentSession(rendererKind:"
        body = start + source.split(start, 1)[1].split(end, 1)[0]
        fixture = (ROOT / "scripts/tests/fixtures/managed_native_action.swift").read_text()
        marker = "// __ACTUAL_MANAGED_ACTION_METHODS__"
        if fixture.count(marker) != 1:
            raise RuntimeError("Exactly one actual AppDelegate managed-action seam required")
        generated = cls.build / "NativeActionFixture.swift"
        generated.write_text(fixture.replace(marker, body))
        sources = [str(generated), str(ROOT / "Sources/AgentSessionProvider.swift"),
                   str(ROOT / "Sources/AgentSessionDebugMenuButtons.swift")]
        wrapper = (ROOT / "Sources/IrohTransportDebugMenuButtons.swift").read_text()
        wrapper_start = "struct IrohAndAgentSessionDebugMenuButtons: View {"
        wrapper_body = wrapper_start + wrapper.split(wrapper_start, 1)[1].split(
            "struct IrohTransportDebugMenuButtons: View {", 1
        )[0]
        wrapper_file = cls.build / "ActualMenuWrapper.swift"
        wrapper_file.write_text("import SwiftUI\n" + wrapper_body)
        sources.append(str(wrapper_file))
        app = (ROOT / "Sources/cmuxApp.swift").read_text()
        call_start = "                IrohAndAgentSessionDebugMenuButtons("
        call_body = call_start + app.split(call_start, 1)[1].split(
            '\n\n                Button("Open Workspaces for All Workspace Colors")', 1
        )[0]
        wiring = cls.build / "ActualMenuWiring.swift"
        wiring.write_text("import SwiftUI\n@MainActor func actualMenuWiring(appDelegate: AppDelegate) -> some View {\n"
                          + call_body + "\n}\n")
        sources.append(str(wiring))
        cls.executable = cls.build / "NativeActionFixture"
        result = subprocess.run(
            ["swiftc", "-swift-version", "5", "-gnone", "-D", "DEBUG", "-parse-as-library",
             *sources, "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=120,
        )
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Actual native action source build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-14000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unqualified_provider_and_renderer_never_prompt_resolve_or_create(self):
        for provider in ["copilot", "codex"]:
            for suffix in ["unqualified", "foreign-provider", "foreign-renderer"]:
                with self.subTest(provider=provider, scenario=suffix):
                    self.scenario(f"{provider}-{suffix}")

    def test_codex_action_uses_only_the_owned_bundled_backend_for_both_renderers(self):
        for suffix in ["react", "solid"]:
            with self.subTest(scenario=suffix):
                self.scenario("codex-" + suffix)

    def test_copilot_action_preserves_its_existing_resolver_and_renderer(self):
        for suffix in ["react", "solid"]:
            with self.subTest(scenario=suffix):
                self.scenario("copilot-" + suffix)

    def test_disclosure_cancel_never_resolves_or_creates_a_session(self):
        for provider in ["copilot", "codex"]:
            with self.subTest(provider=provider):
                self.scenario(provider + "-cancel")

    def test_native_owner_changes_during_disclosure_fail_before_executable_resolution(self):
        for provider in ["copilot", "codex"]:
            for suffix in ["manager-lost", "workspace-lost", "pane-missing"]:
                with self.subTest(provider=provider, scenario=suffix):
                    self.scenario(f"{provider}-{suffix}")

    def test_missing_owned_codex_backend_is_reported_without_manual_or_path_fallback(self):
        self.scenario("codex-helper-missing")

    def test_created_entry_keeps_the_current_native_object_getter(self):
        for provider in ["copilot", "codex"]:
            with self.subTest(provider=provider):
                self.scenario(provider + "-owner-getter")

    def test_real_provider_enum_refuses_unsupported_managed_app_actions(self):
        self.scenario("codex-unsupported-native-provider")


if __name__ == "__main__":
    unittest.main()
