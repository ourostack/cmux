"""Actual native Copilot startup over owned, supervised private pipes; no provider/model."""

import json
import subprocess
import unittest

import test_managed_process_bootstrap as bootstrap


class ManagedCopilotStartupTests(bootstrap.ManagedProcessBootstrapTests):
    def startup(self, scenario):
        result = subprocess.run(
            [str(self.executable), "--fixture-copilot-startup", scenario],
            capture_output=True, timeout=20 if scenario.startswith("owner-tool-") else 12,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def test_root_callback_executes_real_read_edit_validate_then_ack_and_fresh_inventories(self):
        result = self.startup("owner-tool-read-edit-validate")
        self.assertTrue(result["inputAccepted"])
        self.assertTrue(result["ackMatchesHost"])
        self.assertEqual(result["callbackFile"], "after\n", result)
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["phase"], "workObserved")
        self.assertEqual(result["callbackExecutions"], "read\nedit\nvalidate\n")
        self.assertEqual(result["nativeOutstanding"], 0)
        self.assertEqual(result["outstandingActivities"], 0)

    def test_callback_before_send_ack_or_root_is_retained_until_exact_join(self):
        for scenario in ("owner-tool-before-send-ack", "owner-tool-external-before-root"):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertEqual(result["reason"], "", result)
                self.assertTrue(result["workEvidence"], result)
                self.assertEqual(result["callbackExecutions"], "read\nedit\nvalidate\n")
                self.assertEqual(result["nativeOutstanding"], 0)

    def test_unowned_or_ambiguous_callback_cannot_execute_any_command(self):
        for suffix in (
            "no-native-authority", "foreign-root", "foreign-session", "foreign-call", "foreign-name",
            "foreign-provider", "foreign-cwd", "parented", "argument-mismatch", "invalid-arguments",
            "hosted-caller", "mcp-root", "nonfunction", "metadata-extra", "metadata-deferred", "metadata-mcp",
        ):
            with self.subTest(scenario=suffix):
                result = self.startup("owner-tool-" + suffix)
                self.assertEqual(result["phase"], "held", result)
                self.assertTrue(result["reason"], result)
                self.assertFalse(result["workEvidence"], result)
                self.assertEqual(result["callbackFile"], "before\n", result)
                self.assertEqual(result["callbackExecutions"], "", result)
                self.assertEqual(result["nativeOutstanding"], 0)

    def test_command_completion_and_ui_dismissal_cannot_replace_strict_response_ack(self):
        for suffix in (
            "refused-ack", "numeric-ack", "extra-ack", "empty-ack", "foreign-ack",
            "duplicate-ack", "missing-ack", "idle-before-ack", "root-before-ack",
        ):
            with self.subTest(scenario=suffix):
                result = self.startup("owner-tool-" + suffix)
                self.assertEqual(result["phase"], "held", result)
                self.assertFalse(result["workEvidence"], result)
                self.assertEqual(result["callbackFile"], "before\n", result)
                self.assertEqual(result["callbackExecutions"], "read\n", result)
                self.assertEqual(result["nativeOutstanding"], 0)
                self.assertGreater(result["outstandingActivities"], 0)

    def test_ui_completion_before_native_result_cannot_release_the_callback(self):
        result = self.startup("owner-tool-ui-before-result")
        self.assertEqual(result["phase"], "held", result)
        self.assertEqual(result["reason"], "callbackMismatch", result)
        self.assertFalse(result["workEvidence"], result)
        self.assertEqual(result["callbackFile"], "before\n")
        self.assertIn(result["callbackExecutions"], ("", "read\n"))

    def test_later_callback_or_permission_request_taints_the_generation_without_follow_on_work(self):
        for suffix in ("overlap", "unrequested-permission"):
            with self.subTest(scenario=suffix):
                result = self.startup("owner-tool-" + suffix)
                self.assertEqual(result["phase"], "held", result)
                self.assertFalse(result["workEvidence"], result)
                self.assertEqual(result["callbackFile"], "before\n")
                self.assertIn(result["callbackExecutions"], ("", "read\n"))

    def test_ui_dismissal_during_result_rpc_wait_does_not_finish_the_callback(self):
        result = self.startup("owner-tool-ui-before-ack")
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["callbackExecutions"], "read\nedit\nvalidate\n")

    def test_native_authority_revocation_stops_the_kept_execution_domain(self):
        result = self.startup("owner-tool-revoked")
        self.assertEqual(result["phase"], "held", result)
        self.assertFalse(result["workEvidence"], result)
        self.assertEqual(result["callbackFile"], "before\n")
        self.assertEqual(result["callbackExecutions"], "")

    def test_known_nonzero_exit_is_an_explicit_failure_result_not_unknown_completion(self):
        result = self.startup("owner-tool-known-failure")
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["callbackFile"], "before\n")
        self.assertEqual(result["callbackExecutions"], "read\n")
        self.assertEqual(result["nativeOutstanding"], 0)

    def test_result_is_bounded_with_explicit_counts_even_under_double_json_escaping(self):
        result = self.startup("owner-tool-large-result")
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["callbackFile"], "before\n")
        self.assertEqual(result["callbackExecutions"], "read\n")
        self.assertEqual(result["nativeOutstanding"], 0)

    def test_exact_tool_telemetry_does_not_replace_callback_result_ack(self):
        result = self.startup("owner-tool-telemetry")
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["callbackExecutions"], "read\nedit\nvalidate\n")

    def test_foreign_or_premature_completion_telemetry_cannot_start_native_work(self):
        for suffix in ("foreign-telemetry", "early-complete-telemetry"):
            with self.subTest(scenario=suffix):
                result = self.startup("owner-tool-" + suffix)
                self.assertEqual(result["phase"], "held", result)
                self.assertFalse(result["workEvidence"], result)
                self.assertEqual(result["callbackFile"], "before\n")
                self.assertEqual(result["callbackExecutions"], "")

    def test_call_and_request_ids_cannot_be_reused_after_a_known_completion(self):
        for suffix in ("replayed-call", "replayed-request"):
            with self.subTest(scenario=suffix):
                result = self.startup("owner-tool-" + suffix)
                self.assertEqual(result["phase"], "held", result)
                self.assertFalse(result["workEvidence"], result)
                self.assertEqual(result["callbackFile"], "before\n")
                self.assertEqual(result["callbackExecutions"], "read\n")
                self.assertEqual(result["nativeOutstanding"], 0)

    def test_invalid_utf8_reports_replacement_policy_and_original_byte_count(self):
        result = self.startup("owner-tool-invalid-utf8")
        self.assertEqual(result["reason"], "", result)
        self.assertTrue(result["workEvidence"], result)
        self.assertEqual(result["callbackFile"], "before\n")
        self.assertEqual(result["callbackExecutions"], "read\n")

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

    def test_owner_root_metadata_must_be_valid_before_any_work_observation(self):
        for scenario in (
            "owner-root-missing-timestamp", "owner-root-wrong-parent", "owner-root-v5-id",
            "owner-root-numeric-ephemeral", "owner-root-missing-ephemeral",
        ):
            with self.subTest(scenario=scenario):
                result = self.startup(scenario)
                self.assertTrue(result["inputAccepted"])
                self.assertEqual(result["phase"], "held")
                self.assertEqual(result["reason"], "invalidEvent")
                self.assertFalse(result["workEvidence"])
                self.assertEqual(result["boundSessionID"], "")

    def test_owner_streaming_uses_real_native_event_metadata_and_exact_final_root(self):
        result = self.startup("owner-streaming")
        self.assertTrue(result["inputAccepted"])
        self.assertTrue(result["ackMatchesHost"])
        self.assertTrue(result["workEvidence"])
        self.assertEqual(result["reason"], "")


if __name__ == "__main__":
    parser = bootstrap.argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=bootstrap.Path)
    options, remaining = parser.parse_known_args()
    bootstrap.MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[bootstrap.sys.argv[0], *remaining])
