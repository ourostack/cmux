"""Actual native Copilot attribution ledger and shared positive-work state; no provider/runtime."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
INPUT = "11111111-1111-4111-8111-111111111111"
SECOND = "22222222-2222-4222-8222-222222222222"


def begin(input_id=INPUT, supervisor=False):
    return {"op": "begin", "inputID": input_id, "supervisor": supervisor}


def ack(provider_id="server-message-A", input_id=INPUT):
    return {"op": "ack", "inputID": input_id, "providerID": provider_id}


def event(kind, data, **extra):
    return {"op": "event", "event": {
        "id": str(uuid.uuid4()), "parentId": None, "timestamp": "2026-10-19T13:00:00.000Z",
        "type": kind, "data": data, **extra,
    }}


def root(provider_id="server-message-A"):
    return [
        event("assistant.turn_start", {"turnId": "0"}),
        event("assistant.message", {"messageId": "assistant-A", "originatingMessageId": provider_id,
                                    "content": "Finished", "turnId": "0", "toolRequests": []}),
        event("assistant.turn_end", {"turnId": "0"}),
        event("session.idle", {"mode": "interactive", "aborted": False}, ephemeral=True),
    ]


def readback(stage, result, **extra):
    return {"op": "readback", "readback": stage, "result": result, **extra}


def clean_work():
    return [
        {"op": "beginWork"}, readback("refresh", {}), readback("tasks", {"tasks": []}),
        readback("schedules", {"entries": []}), readback("pendingTools", {"items": []}),
    ]


class ManagedCopilotTurnLedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-copilot-turn-ledger-source-"))
        print(f"Retained exact-source ledger build: {cls.build}", file=sys.stderr)
        control = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd"
        flags = ["swiftc", "-swift-version", "6", "-gnone", "-module-cache-path",
                 str(MODULE_CACHE or cls.build / "cache")]
        commands = [
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxControlSocket",
                     str(control / "ShepherdManagedSessionIdentity.swift"),
                     str(control / "ShepherdManagedSessionState.swift"),
                     "-o", str(cls.build / "libCmuxControlSocket.dylib")],
            flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build), "-lCmuxControlSocket",
                     "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
                     str(ROOT / "Sources/Panels/CopilotManagedTurnLedger.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_copilot_turn_ledger_main.swift"),
                     "-o", str(cls.build / "ledger")],
        ]
        for command in commands:
            result = subprocess.run(command, cwd=cls.build, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "ledger"

    def run_ledger(self, actions):
        result = subprocess.run([str(self.executable)], input=json.dumps(actions),
                                capture_output=True, text=True, timeout=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exact_server_id_root_and_four_observed_work_steps_are_required(self):
        rows = self.run_ledger([begin(), ack(), *root(), *clean_work()])
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertFalse(any(row["complete"] for row in rows[:-1]))
        self.assertTrue(rows[-1]["complete"])

    def test_early_root_events_replay_only_after_the_exact_send_ack(self):
        rows = self.run_ledger([begin(), *root(), ack(), *clean_work()])
        self.assertFalse(any(row["complete"] for row in rows[:6]))
        self.assertTrue(rows[-1]["complete"])

    def test_foreign_server_id_cannot_join_the_latest_pending_host_input(self):
        rows = self.run_ledger([begin(), *root("server-message-foreign"), ack(), *clean_work()])
        self.assertFalse(rows[-1]["complete"])
        self.assertEqual(rows[-1]["failure"], "foreignRoot")

    def test_foreign_host_uuid_cannot_claim_the_send_ack(self):
        rows = self.run_ledger([begin(), ack(input_id=SECOND), *root(), *clean_work()])
        self.assertFalse(rows[-1]["complete"])
        self.assertEqual(rows[-1]["failure"], "inputMismatch")

    def test_idle_alone_is_not_root_completion(self):
        rows = self.run_ledger([begin(), ack(),
                                event("session.idle", {"mode": "interactive", "aborted": False}),
                                *clean_work()])
        self.assertFalse(rows[-1]["complete"])
        self.assertEqual(rows[-1]["failure"], "rootAttributionUnavailable")

    def test_assistant_idle_does_not_complete_or_permit_work_readback(self):
        events = root()[:-1] + [event("assistant.idle", {"aborted": False})]
        rows = self.run_ledger([begin(), ack(), *events, {"op": "beginWork"}])
        self.assertFalse(rows[-1]["accepted"])
        self.assertFalse(rows[-1]["complete"])

    def test_subagent_message_cannot_finish_the_root(self):
        events = root()
        events[1]["event"]["agentId"] = "subagent"
        rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
        self.assertEqual(rows[-1]["failure"], "foreignParticipant")
        self.assertFalse(rows[-1]["complete"])

    def test_unmatched_turn_end_cannot_complete_the_root(self):
        events = root()
        events[2]["event"]["data"]["turnId"] = "foreign"
        rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
        self.assertEqual(rows[-1]["failure"], "unmatchedTurn")
        self.assertFalse(rows[-1]["complete"])

    def test_aborted_or_autopilot_idle_is_not_success(self):
        for replacement in ({"mode": "interactive", "aborted": True}, {"mode": "autopilot", "aborted": False}):
            with self.subTest(replacement=replacement):
                events = root()
                events[-1]["event"]["data"] = replacement
                rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
                self.assertFalse(rows[-1]["complete"])
                self.assertEqual(rows[-1]["failure"], "rootNotSuccessful")

    def test_duplicate_event_ids_invalidate_positive_evidence(self):
        events = root()
        rows = self.run_ledger([begin(), ack(), *events, events[0], *clean_work()])
        self.assertEqual(rows[-1]["failure"], "replayedEvent")
        self.assertFalse(rows[-1]["complete"])

    def test_unknown_activity_during_work_readbacks_invalidates_the_snapshot(self):
        actions = [begin(), ack(), *root(), *clean_work()[:3],
                   event("background_tasks.changed", {}), *clean_work()[3:]]
        rows = self.run_ledger(actions)
        self.assertFalse(rows[-1]["complete"])
        self.assertEqual(rows[-1]["failure"], "unsupportedEvent")

    def test_missing_or_nonempty_work_domain_never_means_drained(self):
        for stage, value in (("tasks", {}), ("tasks", {"tasks": [{"id": "foreign", "kind": "client"}]}),
                             ("schedules", {"entries": [{"id": 1}]}),
                             ("pendingTools", {"items": [{"requestId": "foreign"}]})):
            with self.subTest(stage=stage, value=value):
                work = clean_work()
                for action in work:
                    if action.get("readback") == stage:
                        action["result"] = value
                rows = self.run_ledger([begin(), ack(), *root(), *work])
                self.assertFalse(rows[-1]["complete"])
                self.assertEqual(rows[-1]["failure"], "workInventoryUnavailable")

    def test_refresh_must_precede_all_other_work_observations(self):
        work = clean_work()
        work[1], work[2] = work[2], work[1]
        rows = self.run_ledger([begin(), ack(), *root(), *work])
        self.assertEqual(rows[-1]["failure"], "workReadbackMismatch")

    def test_foreign_inspection_token_cannot_finish_a_work_observation(self):
        work = clean_work()
        work[-1]["foreignToken"] = True
        rows = self.run_ledger([begin(), ack(), *root(), *work])
        self.assertEqual(rows[-1]["failure"], "workReadbackMismatch")
        self.assertFalse(rows[-1]["complete"])

    def test_supervisor_input_requires_prior_positive_work_evidence(self):
        blocked = self.run_ledger([begin(supervisor=True)])
        self.assertFalse(blocked[-1]["accepted"])
        allowed = self.run_ledger([begin(), ack(), *root(), *clean_work(), begin(SECOND, supervisor=True)])
        self.assertTrue(allowed[-1]["accepted"])
        self.assertFalse(allowed[-1]["complete"])

    def test_early_event_buffer_cannot_grow_without_a_send_ack(self):
        events = [event("assistant.intent", {"intent": "working"}) for _ in range(65)]
        rows = self.run_ledger([begin(), *events])
        self.assertEqual(rows[-1]["failure"], "earlyEventOverflow")
        self.assertFalse(rows[-1]["complete"])

    def test_root_attribution_rejects_legacy_subagent_parent_tool_identity(self):
        events = root()
        events[1]["event"]["data"]["parentToolCallId"] = "child-parent-tool"
        rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
        self.assertEqual(rows[-1]["failure"], "foreignParticipant")
        self.assertFalse(rows[-1]["complete"])

    def test_even_diagnostic_activity_invalidates_an_inflight_work_observation(self):
        work = clean_work()
        rows = self.run_ledger([begin(), ack(), *root(), *work[:3],
                                event("assistant.intent", {"intent": "additional activity"}),
                                *work[3:]])
        self.assertEqual(rows[-1]["failure"], "workReadbackMismatch")
        self.assertFalse(rows[-1]["complete"])

    def test_optional_idle_fields_follow_the_pinned_sdk_non_aborted_default(self):
        for idle_data in ({}, {"mode": "interactive"}, {"aborted": False}):
            with self.subTest(idle_data=idle_data):
                events = root()
                events[-1]["event"]["data"] = idle_data
                rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
                self.assertTrue(rows[-1]["complete"], rows)
                self.assertEqual(rows[-1]["failure"], "")

    def test_optional_idle_fields_do_not_allow_null_wrong_types_or_unknown_modes(self):
        for idle_data in ({"aborted": 0}, {"aborted": None}, {"mode": None},
                          {"mode": "unknown", "aborted": False}):
            with self.subTest(idle_data=idle_data):
                events = root()
                events[-1]["event"]["data"] = idle_data
                rows = self.run_ledger([begin(), ack(), *events, *clean_work()])
                self.assertFalse(rows[-1]["complete"])
                self.assertEqual(rows[-1]["failure"], "rootNotSuccessful")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
