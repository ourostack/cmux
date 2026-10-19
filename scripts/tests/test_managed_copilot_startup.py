"""Actual native Copilot startup over owned, supervised private pipes; no provider/model."""

import json
import subprocess
import unittest

import test_managed_process_bootstrap as bootstrap


class ManagedCopilotStartupTests(bootstrap.ManagedProcessBootstrapTests):
    def startup(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-copilot-startup", scenario],
            capture_output=True, timeout=12,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def test_verified_startup_binds_exact_preregistered_session_but_cannot_admit_input(self):
        result = self.startup("valid")
        self.assertEqual(result["phase"], "awaitingReadback")
        self.assertEqual(result["boundSessionID"], result["sessionID"])
        self.assertEqual(result["nativePhase"], "bound")

    def test_create_time_event_uses_the_preregistered_session(self):
        result = self.startup("early-event")
        self.assertEqual(result["phase"], "awaitingReadback")
        self.assertEqual(result["bufferedEvents"], 1)

    def test_foreign_generation_cannot_start_the_current_transport(self):
        result = self.startup("stale-start")
        self.assertEqual(result["phase"], "idle")
        self.assertEqual(result["boundSessionID"], "")

    def test_dead_backend_cannot_start_a_handshake(self):
        result = self.startup("dead-before-start")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "transportUnavailable")
        self.assertEqual(result["boundSessionID"], "")

    def test_incompatible_or_unsuccessful_connect_never_creates_a_session(self):
        for scenario in ("wrong-protocol", "wrong-version", "not-ok"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "incompatiblePeer")
                self.assertEqual(result["boundSessionID"], "")

    def test_create_response_cannot_replace_the_local_session_id(self):
        result = self.startup("wrong-session")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "sessionMismatch")
        self.assertEqual(result["boundSessionID"], "")

    def test_unknown_response_id_is_not_joined_to_the_latest_request(self):
        result = self.startup("unknown-id")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "unregisteredResponse")

    def test_duplicate_response_invalidates_the_request_ledger(self):
        result = self.startup("duplicate")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "unregisteredResponse")
        self.assertEqual(result["boundSessionID"], "")

    def test_error_response_does_not_trigger_legacy_fallback(self):
        result = self.startup("error")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "rpcError")

    def test_ambiguous_or_incomplete_response_is_not_a_success(self):
        for scenario in ("ambiguous-response", "missing-result"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "invalidEnvelope")

    def test_unrequested_server_callback_cannot_dispatch_a_tool(self):
        result = self.startup("server-request")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "unsupportedCallback")

    def test_foreign_session_notification_invalidates_startup(self):
        result = self.startup("foreign-event")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "sessionMismatch")

    def test_missing_response_expires_without_retry_or_identity(self):
        result = self.startup("timeout")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "responseTimeout")
        self.assertEqual(result["boundSessionID"], "")


if __name__ == "__main__":
    parser = bootstrap.argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=bootstrap.Path)
    options, remaining = parser.parse_known_args()
    bootstrap.MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[bootstrap.sys.argv[0], *remaining])
