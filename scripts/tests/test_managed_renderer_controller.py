"""Compile the actual native controller and writer against controlled native/bridge facts."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedRendererControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-renderer-controller-"))
        print(f"Retained native controller fixture: {cls.build}", file=sys.stderr)
        names = [
            "Sources/Panels/AgentSessionManagedRendererReservation.swift",
            "Sources/Panels/AgentSessionManagedRendererController.swift",
            "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd/ShepherdManagedPipeWriter.swift",
            "scripts/tests/fixtures/managed_renderer_controller.swift",
        ]
        sources = []
        for name in names:
            target = cls.build / Path(name).name
            if (ROOT / name).exists():
                shutil.copy2(ROOT / name, target)
                sources.append(str(target))
        cls.executable = cls.build / "ControllerFixture"
        result = subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-gnone",
            "-module-name", "ManagedRendererControllerSource", "-o", str(cls.executable), *sources,
        ], capture_output=True, text=True, timeout=240)
        (cls.build / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Native controller compilation failed; {cls.build / 'build.log'}\n"
                               + (result.stdout + result.stderr)[-12000:])

    def scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=10)
        (self.build / f"{name}.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_capture_is_bound_to_native_controller_and_current_context(self):
        self.scenario("snapshot-custody")

    def test_native_insertion_cannot_replace_a_captured_human_draft(self):
        for scenario in ["draft-refused", "draft-whitespace"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_submission_binds_the_exact_inserted_literal_input_uuid_and_native_custody(self):
        for scenario in ["submission-literal", "submission-custody"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_revoked_or_expired_bound_submission_cannot_admit_a_real_pipe_byte(self):
        for scenario in ["submission-revoked", "submission-expired",
                         "submission-foreign-owner", "submission-foreign-store"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_reentrant_native_validation_cannot_claim_the_same_submission_twice(self):
        self.scenario("submission-claim-reentry")

    def test_invalidated_capture_reply_cannot_create_a_snapshot(self):
        self.scenario("capture-reentry")

    def test_original_observation_deadline_cannot_be_renewed_by_capture_or_insertion(self):
        for scenario in ["capture-late-reply", "capture-expired",
                         "capture-delayed-insertion", "capture-clipped-frame"]:
            with self.subTest(scenario=scenario):
                self.scenario(scenario)

    def test_late_insertion_is_released_without_a_frame(self):
        self.scenario("insert-reentry")

    def test_snapshot_and_receipt_decoding_reject_malformed_bridge_values(self):
        self.scenario("strict-dictionaries")

    def test_only_a_real_boolean_can_confirm_renderer_validation(self):
        self.scenario("strict-boolean")

    def test_native_separation_and_single_claim_constrain_the_real_writer(self):
        self.scenario("writer-success")

    def test_context_loss_after_validation_prevents_the_first_pipe_byte(self):
        self.scenario("writer-revocation")

    def test_event_during_backpressure_stops_the_next_actual_syscall(self):
        self.scenario("writer-backpressure")

    def test_reentrant_validation_cannot_revive_an_invalidated_frame(self):
        self.scenario("validate-reentry")

    def test_bridge_failure_revokes_the_reservation_and_propagates(self):
        self.scenario("bridge-error")

    def test_completed_insertion_releases_only_its_own_native_reservation(self):
        self.scenario("finish-custody")

    def test_expired_insertion_releases_before_a_fresh_capture(self):
        self.scenario("expired-recovery")

    def test_separation_starts_after_the_actual_insertion_reply(self):
        self.scenario("delayed-insertion")

    def test_expiry_while_awaiting_validation_cannot_mint_a_frame(self):
        self.scenario("validate-expiry")

    def test_sleep_cancellation_revokes_and_propagates_without_validation(self):
        self.scenario("cancelled-separation")

    def test_lease_release_failure_is_explicitly_reported(self):
        self.scenario("release-error")


if __name__ == "__main__":
    unittest.main()
