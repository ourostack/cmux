"""Tiny source-only Git posture checks; no Git, compiler, provider, or network launch."""
from contextlib import ExitStack
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts/build-managed-codex-host.py"
SPEC = importlib.util.spec_from_file_location("managed_codex_git_posture_build", SOURCE)
BUILD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILD
SPEC.loader.exec_module(BUILD)


class CapturedExec(RuntimeError):
    pass


class ManagedCodexGitPostureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="cmux-managed-codex-git-unit-")).resolve()
        self.target = self.root / "target"
        self.target.mkdir()
        self.forbidden = ExitStack()
        for name in ("subprocess.run", "subprocess.Popen", "os.system", "os.execv", "os.execve",
                     "urllib.request.urlopen"):
            self.forbidden.enter_context(patch(
                name, side_effect=AssertionError("Real process or network launch forbidden")))
        self.addCleanup(self.forbidden.close)
        print(f"Retained tiny Git fixture: {self.root}", file=sys.stderr)

    def gateway(self):
        directory, digest = BUILD._cargo_git_gateway(self.target, "fixture")
        data = (directory / "git").read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        self.assertTrue(data.splitlines()[0].endswith(b" -B"))
        return data.decode()

    def execute_gateway(self, text, arguments, additions=None, cwd=None):
        captured = {}

        def capture(executable, argv, environment):
            captured.update(executable=executable, argv=argv, environment=environment)
            raise CapturedExec

        ambient = {"GIT_CONFIG": "/never-read", "GIT_CONFIG_COUNT": "7",
                   "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='/never-execute'",
                   **(additions or {})}
        with patch.object(Path, "cwd", return_value=cwd or self.root), \
                patch.object(sys, "argv", ["owned-git", *arguments]), \
                patch.dict(os.environ, ambient), patch.object(os, "execve", side_effect=capture):
            try:
                exec(compile(text, "<owned-cargo-git-gateway>", "exec"), {})
            except CapturedExec:
                return captured
        self.fail("Gateway did not attempt the controlled system-Git handoff")

    def test_normal_product_import_does_not_require_bytecode_mode(self):
        module = ModuleType("managed_codex_default_import")
        module.__file__ = str(SOURCE)
        with patch.dict(sys.modules, {module.__name__: module}), \
                patch.object(sys, "dont_write_bytecode", False):
            exec(compile(SOURCE.read_bytes(), str(SOURCE), "exec"), module.__dict__)
        self.assertTrue(callable(module.prepare_stage))
        self.assertTrue(callable(module.run_locked))

    def test_patch_command_disables_ambient_git_automation(self):
        with patch.dict(os.environ, {"GIT_CONFIG_COUNT": "7", "GIT_DIR": "/foreign",
                                    "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='/never-execute'"}), \
                patch.object(BUILD.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout="", stderr="")) as captured:
            BUILD._git_apply(self.root, self.root / "fixture.patch", check=True)
        arguments = captured.call_args.args[0]
        self.assertEqual(arguments[:3], ["git", "-c", "core.fsmonitor="])
        for value in ("maintenance.auto=false", "gc.auto=0", "core.hooksPath=" + os.devnull,
                      "credential.helper=", "apply", "--check"):
            self.assertIn(value, arguments)
        environment = captured.call_args.kwargs["env"]
        self.assertEqual(environment["GIT_CONFIG_COUNT"], "0")
        self.assertEqual(environment["GIT_CONFIG_SYSTEM"], os.devnull)
        self.assertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        self.assertFalse("GIT_DIR" in environment)
        self.assertFalse("GIT_CONFIG_PARAMETERS" in environment)

    def test_gateway_keeps_owned_gitdir_and_sanitizes_ambient_config(self):
        owned = self.root / "owned.git"
        owned.mkdir()
        captured = self.execute_gateway(self.gateway(), ["fetch", "--no-tags"],
                                        {"GIT_DIR": str(owned)})
        self.assertTrue(Path(captured["executable"]).is_absolute())
        self.assertEqual(captured["argv"][:3],
                         [captured["executable"], "--git-dir", str(owned)])
        for value in ("core.fsmonitor=", "core.hooksPath=" + os.devnull,
                      "maintenance.auto=false", "gc.auto=0", "credential.helper="):
            self.assertIn(value, captured["argv"])
        environment = captured["environment"]
        self.assertEqual(environment["GIT_CONFIG_COUNT"], "0")
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        self.assertFalse("GIT_CONFIG" in environment)
        self.assertFalse("GIT_CONFIG_PARAMETERS" in environment)
        self.assertFalse("GIT_DIR" in environment)

    def test_gateway_rejects_config_override_or_foreign_paths_before_handoff(self):
        text = self.gateway()
        for arguments, additions in (
            (["-c", "core.fsmonitor=/never-execute", "status"], {}),
            (["-cCORE.FSMONITOR=/never-execute", "status"], {}),
            (["--config-env=core.fsmonitor=NEVER", "status"], {}),
            (["config", "Core.HooksPath", "/never-use"], {}),
            (["--git-dir=/outside", "status"], {}),
            (["--work-tree", "/outside", "status"], {}),
            (["-C", "..", "status"], {}),
            (["fetch"], {"GIT_DIR": str(self.root.parent)}),
        ):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                self.execute_gateway(text, arguments, additions)

    def test_gateway_rejects_foreign_cwd_before_handoff(self):
        with self.assertRaises(SystemExit):
            self.execute_gateway(self.gateway(), ["status"], cwd=self.root.parent)


if __name__ == "__main__":
    unittest.main()
