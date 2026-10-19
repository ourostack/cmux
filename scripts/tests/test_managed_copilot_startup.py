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
        self.assertEqual(result["phase"], "configurationObserved")
        self.assertEqual(result["boundSessionID"], result["sessionID"])
        self.assertEqual(result["nativePhase"], "bound")

    def test_create_time_event_uses_the_preregistered_session(self):
        result = self.startup("early-event")
        self.assertEqual(result["phase"], "configurationObserved")
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

    def test_unsuccessful_options_update_invalidates_the_bound_session(self):
        result = self.startup("options-refused")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "configurationRefused")
        self.assertEqual(result["boundSessionID"], "")

    def test_startup_requires_all_effective_readbacks_not_an_empty_pending_map(self):
        result = self.startup("valid")
        self.assertEqual(result["phase"], "configurationObserved")
        self.assertEqual(result["reason"], "")

    def test_inherited_or_unknown_effective_inventory_invalidates_identity(self):
        for scenario in ("inherited-agent", "selected-agent", "missing-current-agent",
                         "inherited-mcp", "managed-plugin", "inherited-extension",
                         "null-tools", "unaccounted-tool"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "configurationMismatch")
                self.assertEqual(result["boundSessionID"], "")

    def test_start_event_requires_real_required_fields_not_a_dictionary_placeholder(self):
        for scenario in ("bad-start-data", "bad-start-shape", "boolean-start-version", "invalid-start-id"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "invalidStartupEvent")

    def test_start_event_cannot_describe_a_foreign_participant(self):
        for scenario in ("foreign-start-data", "already-in-use", "remote-steerable",
                         "detached-start", "subagent-start"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "foreignParticipant")
                self.assertEqual(result["boundSessionID"], "")

    def test_missing_start_event_is_not_fresh_session_evidence(self):
        result = self.startup("missing-start")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "startupEventUnavailable")

    def test_duplicate_start_event_cannot_enter_the_startup_buffer_twice(self):
        result = self.startup("duplicate-start")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "duplicateStartupEvent")

    def test_kernel_revalidation_does_not_wait_for_the_lifetime_monitor(self):
        result = self.startup("kernel-dead-before-start")
        self.assertEqual(result["nativeBeforeStart"], "awaitingProvider")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "transportUnavailable")
        self.assertEqual(result["boundSessionID"], "")

    def test_native_profile_explicitly_excludes_inherited_and_automatic_context_sources(self):
        result = self.startup("strict-profile")
        self.assertEqual(result["phase"], "configurationObserved")
        self.assertEqual(result["boundSessionID"], result["sessionID"])

    def test_owner_send_joins_exact_server_ack_then_reads_all_work_inventories(self):
        result = self.startup("owner-send")
        self.assertTrue(result["inputAccepted"])
        self.assertFalse(result["secondAccepted"])
        self.assertTrue(result["ackMatchesHost"])
        self.assertTrue(result["workEvidence"])
        self.assertEqual(result["reason"], "")

    def test_root_events_before_send_ack_are_retained_under_the_preregistered_host_input(self):
        result = self.startup("owner-early-root")
        self.assertTrue(result["inputAccepted"])
        self.assertTrue(result["ackMatchesHost"])
        self.assertTrue(result["workEvidence"])

    def test_ack_and_root_idle_cannot_hide_a_nonempty_work_inventory(self):
        result = self.startup("owner-background-task")
        self.assertTrue(result["inputAccepted"])
        self.assertFalse(result["workEvidence"])
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "workInventoryUnavailable")
        self.assertEqual(result["boundSessionID"], "")

    def test_send_ack_requires_a_valid_server_owned_message_id(self):
        for scenario in ("owner-missing-ack-id", "owner-empty-ack-id", "owner-null-ack-id"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertTrue(result["inputAccepted"])
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "invalidSendAcknowledgement")
                self.assertFalse(result["workEvidence"])
                self.assertEqual(result["boundSessionID"], "")

    def test_unregistered_or_duplicate_send_ack_never_binds_to_the_current_input(self):
        for scenario in ("owner-foreign-ack", "owner-duplicate-ack"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "unregisteredResponse")
                self.assertFalse(result["workEvidence"])

    def test_foreign_root_and_idle_without_a_root_are_not_success(self):
        for scenario, reason in (("owner-foreign-root", "foreignRoot"),
                                 ("owner-idle-without-root", "rootAttributionUnavailable"),
                                 ("owner-aborted", "rootNotSuccessful")):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], reason)
                self.assertFalse(result["workEvidence"])

    def test_send_ack_or_ended_turn_without_session_idle_is_not_work_evidence(self):
        for scenario in ("owner-ack-only", "owner-no-idle"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertTrue(result["inputAccepted"])
                self.assertTrue(result["ackMatchesHost"])
                self.assertFalse(result["workEvidence"])
                self.assertEqual(result["phase"], "awaitingRoot")

    def test_each_work_inventory_must_be_explicit_and_empty(self):
        for scenario in ("owner-scheduled", "owner-pending-tool", "owner-missing-tasks"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "workInventoryUnavailable")
                self.assertFalse(result["workEvidence"])

    def test_new_provider_activity_invalidates_inflight_work_readbacks(self):
        result = self.startup("owner-work-activity")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "workReadbackMismatch")
        self.assertFalse(result["workEvidence"])

    def test_stale_launch_cannot_submit_input_on_the_current_pipe(self):
        result = self.startup("owner-stale-launch")
        self.assertFalse(result["inputAccepted"])
        self.assertFalse(result["ackMatchesHost"])
        self.assertEqual(result["phase"], "configurationObserved")

    def test_second_input_is_not_queued_while_a_root_is_inflight(self):
        result = self.startup("owner-ack-only")
        self.assertTrue(result["inputAccepted"])
        self.assertFalse(result["secondAccepted"])
        self.assertEqual(result["phase"], "awaitingRoot")

    def test_owner_input_before_configuration_or_with_blank_prompt_writes_nothing(self):
        for scenario in ("owner-before-start", "owner-whitespace"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertFalse(result["inputAccepted"])
                self.assertFalse(result["ackMatchesHost"])
                self.assertFalse(result["workEvidence"])
                self.assertEqual(result["phase"], "configurationObserved")

    def test_completed_owner_turn_can_be_followed_by_a_new_exact_acknowledged_turn(self):
        result = self.startup("owner-next-input")
        self.assertTrue(result["nextAccepted"])
        self.assertTrue(result["nextAckMatchesHost"])
        self.assertTrue(result["workEvidence"])
        self.assertEqual(result["reason"], "")

    def test_reused_host_input_id_does_not_enqueue_another_provider_request(self):
        result = self.startup("owner-reused-host")
        self.assertFalse(result["nextAccepted"])
        self.assertEqual(result["reason"], "inputLedgerConflict")
        self.assertFalse(result["workEvidence"])

    def test_reused_provider_message_id_cannot_bind_a_different_host_input(self):
        result = self.startup("owner-reused-provider")
        self.assertTrue(result["nextAccepted"])
        self.assertFalse(result["nextAckMatchesHost"])
        self.assertEqual(result["reason"], "inputMismatch")
        self.assertFalse(result["workEvidence"])

    def test_late_root_for_previous_input_cannot_complete_the_next_owner_input(self):
        result = self.startup("owner-late-prior-root")
        self.assertTrue(result["nextAccepted"])
        self.assertTrue(result["nextAckMatchesHost"])
        self.assertEqual(result["reason"], "foreignRoot")
        self.assertFalse(result["workEvidence"])

    def test_configuration_notifications_from_owned_startup_mutations_allow_fresh_readbacks(self):
        for stage in ("create", "options", "initialize"):
            with self.subTest(stage=stage):
                result = self.startup(f"configuration-at-{stage}")
                self.assertEqual(result["phase"], "configurationObserved")
                self.assertEqual(result["bufferedEvents"], 6)
                self.assertEqual(result["boundSessionID"], result["sessionID"])

    def test_configuration_initialization_precedes_every_effective_inventory_read(self):
        result = self.startup("configuration-readback-order")
        self.assertEqual(result["phase"], "configurationObserved")
        self.assertEqual(result["reason"], "")

    def test_configuration_notices_cannot_replace_post_initialization_inventory_evidence(self):
        result = self.startup("configuration-stale-readback")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "configurationMismatch")
        self.assertEqual(result["boundSessionID"], "")

    def test_configuration_notice_before_start_does_not_replace_the_required_start_event(self):
        result = self.startup("configuration-before-start")
        self.assertEqual(result["phase"], "configurationObserved")
        self.assertEqual(result["bufferedEvents"], 2)
        result = self.startup("configuration-without-start")
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "startupEventUnavailable")

    def test_configuration_notice_rejects_nonempty_or_unknown_domain_payloads(self):
        for domain in ("skills", "agents", "errors", "warnings", "mcp", "extensions", "model", "extra"):
            with self.subTest(domain=domain):
                result = self.startup(f"configuration-nonempty-{domain}")
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "configurationMismatch")
                self.assertEqual(result["boundSessionID"], "")

    def test_configuration_notice_requires_complete_typed_native_event_metadata(self):
        for field in ("id", "uuid-version", "timestamp", "parent", "ephemeral"):
            with self.subTest(field=field):
                result = self.startup(f"configuration-malformed-{field}")
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "invalidConfigurationEvent")

    def test_configuration_notice_cannot_describe_a_foreign_participant(self):
        for field in ("agent", "parent"):
            with self.subTest(field=field):
                result = self.startup(f"configuration-foreign-{field}")
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "foreignParticipant")

    def test_configuration_notice_ids_cannot_replay_each_other_or_the_start_event(self):
        for scenario in ("configuration-duplicate", "configuration-start-replay"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "replayedConfigurationEvent")

    def test_configuration_notification_buffer_has_a_hard_generation_limit(self):
        accepted = self.startup("configuration-limit")
        self.assertEqual(accepted["phase"], "configurationObserved")
        self.assertEqual(accepted["bufferedEvents"], 64)
        rejected = self.startup("configuration-overflow")
        self.assertEqual(rejected["phase"], "held")
        self.assertEqual(rejected["reason"], "eventBufferOverflow")

    def test_configuration_notices_during_inventory_reads_or_after_observation_invalidate_identity(self):
        for scenario in ("configuration-during-readback", "configuration-late"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "configurationChanged")
                self.assertEqual(result["boundSessionID"], "")

    def test_configuration_changes_during_a_root_invalidate_input_and_work_evidence(self):
        result = self.startup("owner-configuration-changed")
        self.assertTrue(result["inputAccepted"])
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "configurationChanged")
        self.assertFalse(result["workEvidence"])

    def test_configuration_event_id_cannot_reappear_as_a_root_event(self):
        result = self.startup("owner-configuration-replay")
        self.assertTrue(result["inputAccepted"])
        self.assertEqual(result["phase"], "held")
        self.assertEqual(result["reason"], "replayedEvent")
        self.assertFalse(result["workEvidence"])


if __name__ == "__main__":
    parser = bootstrap.argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=bootstrap.Path)
    options, remaining = parser.parse_known_args()
    bootstrap.MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[bootstrap.sys.argv[0], *remaining])
