"""Compile and exercise the actual native foreground command composition."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

import test_managed_process_bootstrap as bootstrap


class ManagedCommandServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bootstrap.ManagedProcessBootstrapTests.setUpClass()
        cls.executable = bootstrap.ManagedProcessBootstrapTests.executable

    def run_service(self, scenario, timeout=12):
        result = subprocess.run(
            [str(self.executable), "--fixture-command-service", scenario],
            capture_output=True, timeout=timeout,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_completed(self, result, status=0):
        self.assertEqual(result["outcome"], "completed", result)
        self.assertEqual(result["status"], status)
        self.assertEqual(result["outstanding"], 0)
        stages = result["stages"]
        self.assertEqual(stages[:5], ["registered", "launched", "bound", "observing", "ready"])
        self.assertLess(stages.index("backendExit"), stages.index("drained"))
        self.assertLess(stages.index("supervisorExit"), stages.index("drained"))
        self.assertEqual(len(stages), 8)
        self.assertNotEqual(result["backend"], result["supervisor"])
        self.assertNotEqual(result["owner"], result["supervisor"])

    def test_actual_native_service_binds_readies_observes_and_drains_fast_command(self):
        result = self.run_service("fast")
        self.assert_completed(result)
        self.assertEqual(result["stdout"], "resumed\n")
        self.assertEqual(result["stderr"], "child-started\n")

    def test_true_stream_eof_is_not_a_substitute_for_actual_exit(self):
        result = self.run_service("delayed-exit")
        self.assert_completed(result)
        self.assertGreaterEqual(result["durationMilliseconds"], 190)

    def test_actual_late_stderr_is_drained_after_stdout_closes(self):
        result = self.run_service("late-stderr")
        self.assert_completed(result)
        self.assertEqual(result["stdout"], "first")
        self.assertEqual(result["stderr"], "late")

    def test_known_nonzero_status_is_not_unknown_coverage(self):
        result = self.run_service("nonzero")
        self.assert_completed(result, status=7)
        self.assertEqual(result["stderr"], "failure")

    def test_generation_invalidated_before_ready_cannot_execute_the_command(self):
        result = self.run_service("invalidate-before-ready")
        self.assertEqual(result["outcome"], "held", result)
        self.assertFalse(result["markerExists"], result)
        self.assertNotIn("ready", result["stages"])
        self.assertEqual(result["outstanding"], 1)

    def test_uncertainty_and_failed_ownership_remain_positive_work_barriers(self):
        for scenario, reason in (
            ("cancel", "cancelled"), ("owner-loss", "ownerUnavailable"),
            ("survivor", "uncertainTermination"), ("reserved", "uncertainTermination"),
            ("output-limit", "outputLimit"), ("launch-failure", "launchFailed"),
            ("missing-receipt", "bootstrapUnavailable"),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_service(scenario)
                self.assertEqual(result["outcome"], "held", result)
                self.assertEqual(result["reason"], reason, result)
                self.assertEqual(result["outstanding"], 1)

    def test_absolute_runtime_limit_holds_and_reaps_without_forced_drain_success(self):
        result = self.run_service("timeout", timeout=68)
        self.assertEqual(result["outcome"], "held", result)
        self.assertEqual(result["reason"], "executionDeadline", result)
        self.assertGreaterEqual(result["durationMilliseconds"], 60_000)
        self.assertLess(result["durationMilliseconds"], 65_000)
        self.assertEqual(result["outstanding"], 1)

    def test_replayed_operation_cannot_execute_again_or_renew_its_failed_registry(self):
        result = self.run_service("replay")
        self.assert_completed(result)
        self.assertTrue(result["replayHeld"])
        self.assertTrue(result["replacementHeld"])

    def test_distinct_commands_reuse_the_same_service_only_after_known_completion(self):
        result = self.run_service("sequential")
        self.assert_completed(result)
        self.assertTrue(result["secondCompleted"], result)
        self.assertEqual(result["outstandingAfterSecond"], 0)

    def test_overlapping_command_is_not_queued_and_invalidates_the_active_work(self):
        result = self.run_service("overlap")
        self.assertEqual(result["outcome"], "held", result)
        self.assertEqual(result["reason"], "registryConflict", result)
        self.assertTrue(result["overlapHeld"], result)
        self.assertEqual(result["outstanding"], 1)

    def test_command_shape_and_resource_limits_are_not_model_overrides(self):
        result = self.run_service("invalid-commands")
        self.assertTrue(all(result["rejected"]))
        self.assertEqual(len(result["rejected"]), 5)
        self.assertEqual(result["outstanding"], 0)

    def test_factory_selects_the_ready_gated_role_without_launching(self):
        nonce = uuid.uuid4()
        result = subprocess.run(
            [str(self.executable), "--fixture-prepare-foreground", str(nonce),
             str(self.executable), "/tmp"],
            capture_output=True, timeout=3,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        prepared = json.loads(result.stdout)
        self.assertEqual(prepared["arguments"], [
            "__managed-foreground-command-supervisor", str(nonce).upper(),
            str(self.executable), "--fixture-child", "literal argument",
        ])
        self.assertFalse(prepared["running"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    bootstrap.MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
