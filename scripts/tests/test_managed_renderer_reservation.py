"""Exercise native renderer guards and the real nonblocking pipe writer without a GUI or provider."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedRendererReservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-renderer-source-"))
        source = cls.build / "Sources/RendererFixture"
        source.mkdir(parents=True)
        print(f"Retained native renderer source package: {cls.build}", file=sys.stderr)
        names = [
            "Sources/Panels/AgentSessionManagedRendererReservation.swift",
            "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd/ShepherdManagedPipeWriter.swift",
            "scripts/tests/fixtures/managed_renderer_reservation.swift",
        ]
        for name in names:
            shutil.copy2(ROOT / name, source)
        cls.executable = cls.build / "RendererFixture"
        result = subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-gnone",
            "-module-name", "ManagedRendererSource", "-o", str(cls.executable),
            *map(str, sorted(source.glob("*.swift"))),
        ], capture_output=True, text=True, timeout=240)
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Actual native renderer source build failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-10000:])

    def run_scenario(self, scenario):
        result = subprocess.run([str(self.executable), scenario], capture_output=True, text=True, timeout=10)
        (self.build / f"{scenario}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_separation_expiry_single_frame_and_stale_receipt(self):
        self.run_scenario("clock-and-receipt")

    def test_lost_host_during_insert_cannot_be_restored_by_a_late_ack(self):
        self.run_scenario("pending-invalidation")

    def test_focus_invalidation_prevents_the_first_actual_pipe_byte(self):
        self.run_scenario("before-first-byte")

    def test_revocation_inside_the_current_host_predicate_remains_latched(self):
        self.run_scenario("reentrant-host-revocation")

    def test_revocation_during_reservation_admission_cannot_mint_a_ticket(self):
        self.run_scenario("reentrant-begin")

    def test_expiry_inside_host_validation_prevents_the_next_syscall(self):
        self.run_scenario("expiry-during-host-check")

    def test_invalidation_during_backpressure_is_checked_before_the_next_syscall(self):
        self.run_scenario("during-backpressure")


if __name__ == "__main__":
    unittest.main()
