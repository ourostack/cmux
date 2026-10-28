"""Exercise request cancellation across the real renderer submission and nonblocking writer."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedInputCancellationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-input-cancellation-"))
        print(f"Retained native request cancellation fixture: {cls.build}", file=sys.stderr)
        sources = []
        for path in [
            "Sources/Panels/AgentSessionManagedRendererController.swift",
            "Sources/Panels/AgentSessionManagedRendererReservation.swift",
            "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd/ShepherdManagedPipeWriter.swift",
            "scripts/tests/fixtures/managed_input_cancellation.swift",
        ]:
            target = cls.build / Path(path).name
            shutil.copy2(ROOT / path, target)
            sources.append(str(target))
        cls.executable = cls.build / "CancellationFixture"
        result = subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-gnone",
            *sources, "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=120)
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Native request cancellation compilation failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_background_cancellation_prevents_claim_without_an_actor_hop(self):
        self.scenario("before-claim")

    def test_cancellation_inside_native_validation_prevents_the_same_claim(self):
        self.scenario("during-claim")

    def test_background_cancellation_prevents_an_independent_writers_first_byte(self):
        self.scenario("before-byte")

    def test_request_cancellation_stops_the_next_syscall_of_an_independent_backpressured_writer(self):
        self.scenario("backpressure")


if __name__ == "__main__":
    unittest.main()
