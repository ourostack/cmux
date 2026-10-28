"""Actual raw decoder/shared ledger; fixtures cannot prove the CLI's hook producer semantics."""

import argparse
import base64
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
PROMPT_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SECOND_PROMPT_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
PROMPT = "Owner input: 雪 🐈"
SESSION = "controlled-session"
CWD = "/controlled-project"


def begin(input_id=INPUT):
    return {"op": "begin", "inputID": input_id, "prompt": PROMPT}


def written(input_id=INPUT):
    return {"op": "written", "inputID": input_id}


def event(kind, **fields):
    return {"op": "event", "event": {"type": kind, **fields}}


def replay(input_id=INPUT):
    return event("user", uuid=input_id, session_id=SESSION, isReplay=True,
                 parent_tool_use_id=None, message={"role": "user", "content": PROMPT})


def hook(kind, request_id, prompt_id=PROMPT_ID, **extra):
    payload = {"session_id": SESSION, "transcript_path": "/controlled-transcript", "cwd": CWD,
               "prompt_id": prompt_id, "hook_event_name": kind}
    payload.update({"prompt": PROMPT, "source": "sdk"} if kind == "UserPromptSubmit" else {
        "stop_hook_active": False, "background_tasks": [], "session_crons": [],
    })
    payload.update(extra)
    return event("control_request", request_id=request_id, request={
        "subtype": "hook_callback", "callback_id": "cmux-" + kind, "input": payload,
    })


def lifecycle(kind, hook_id, subtype, **extra):
    fields = {"uuid": str(uuid.uuid4()), "session_id": SESSION, "hook_id": hook_id,
              "hook_name": "fixture-sdk-hook", "hook_event": kind}
    if subtype == "hook_response":
        fields.update(outcome="success", output="", stdout="", stderr="")
    fields.update(extra)
    return event("system", subtype=subtype, **fields)


def callback_written(request_id):
    return {"op": "callbackWritten", "requestID": request_id}


def result(input_id=INPUT):
    return event("result", uuid=str(uuid.uuid4()), session_id=SESSION, subtype="success", is_error=False,
                 user_message_uuid=input_id, user_message_uuids=[input_id], queued_turn_count=0)


def idle():
    return event("system", subtype="session_state_changed", state="idle",
                 uuid=str(uuid.uuid4()), session_id=SESSION)


def turn(input_id=INPUT, prompt_id=PROMPT_ID, suffix="A"):
    return [
        begin(input_id), written(input_id), replay(input_id),
        hook("UserPromptSubmit", "submit-" + suffix, prompt_id),
        lifecycle("UserPromptSubmit", "life-submit-" + suffix, "hook_started"),
        callback_written("submit-" + suffix),
        lifecycle("UserPromptSubmit", "life-submit-" + suffix, "hook_response"),
        hook("Stop", "stop-" + suffix, prompt_id),
        lifecycle("Stop", "life-stop-" + suffix, "hook_started"),
        callback_written("stop-" + suffix),
        lifecycle("Stop", "life-stop-" + suffix, "hook_response"),
        result(input_id), idle(),
    ]


class ManagedClaudeTurnLedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-claude-turn-ledger-source-"))
        print(f"Retained exact-source Claude ledger build: {cls.build}", file=sys.stderr)
        control = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd"
        flags = ["swiftc", "-swift-version", "6", "-gnone", "-module-cache-path",
                 str(MODULE_CACHE or cls.build / "cache")]
        commands = [
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxControlSocket",
                     str(control / "ShepherdManagedSessionIdentity.swift"),
                     str(control / "ShepherdManagedSessionState.swift"),
                     str(control / "ShepherdManagedPipeWriter.swift"),
                     "-o", str(cls.build / "libCmuxControlSocket.dylib")],
            flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build), "-lCmuxControlSocket",
                     "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
                     str(ROOT / "Sources/Panels/AgentSessionManagedJSON.swift"),
                     str(ROOT / "Sources/Panels/ClaudeManagedStreamDecoder.swift"),
                     str(ROOT / "Sources/Panels/ClaudeManagedTurnLedger.swift"),
                     str(ROOT / "scripts/tests/fixtures/managed_claude_turn_ledger_main.swift"),
                     "-o", str(cls.build / "ledger")],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "ledger"

    def run_ledger(self, actions):
        response = subprocess.run([str(self.executable)], input=json.dumps(actions),
                                  capture_output=True, text=True, timeout=4)
        self.assertEqual(response.returncode, 0, response.stderr)
        return json.loads(response.stdout)

    def test_all_exact_independent_facts_are_required_before_positive_work_evidence(self):
        rows = self.run_ledger(turn())
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertFalse(any(row["complete"] for row in rows[:-1]), rows)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[-1]["outstanding"], 0)

    def test_provider_prompt_uuid_is_joined_not_assumed_equal_to_host_uuid(self):
        actions = turn()
        actions[-1]["lookupPromptID"] = PROMPT_ID
        rows = self.run_ledger(actions)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[-1]["providerInputID"], INPUT)

    def test_each_missing_gate_withholds_readiness_even_if_every_other_fact_arrives(self):
        for omitted in range(1, len(turn())):
            with self.subTest(omitted=omitted):
                actions = turn()
                actions.pop(omitted)
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)

    def test_static_callback_routes_are_reusable_but_invocation_ids_are_not(self):
        rows = self.run_ledger(turn() + turn(SECOND, SECOND_PROMPT_ID, "B"))
        self.assertTrue(rows[12]["complete"], rows)
        self.assertTrue(rows[-1]["complete"], rows)
        for old_id in ("submit-A", "stop-A"):
            actions = turn() + turn(SECOND, SECOND_PROMPT_ID, "B")
            actions[16 if old_id == "submit-A" else 20]["event"]["request_id"] = old_id
            with self.subTest(old_id=old_id):
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_no_new_input_can_start_before_prior_producer_and_host_work_settle(self):
        for cut in range(1, len(turn())):
            with self.subTest(cut=cut):
                rows = self.run_ledger(turn()[:cut] + [begin(SECOND)])
                self.assertFalse(rows[-1]["accepted"], rows)
                self.assertFalse(rows[-1]["complete"], rows)

    def test_lifecycle_can_start_before_control_but_cannot_succeed_before_the_exact_host_write(self):
        actions = turn()
        actions[7], actions[8] = actions[8], actions[7]
        self.assertTrue(self.run_ledger(actions)[-1]["complete"])
        actions = turn()
        actions[9], actions[10] = actions[10], actions[9]
        rows = self.run_ledger(actions)
        self.assertFalse(rows[-1]["complete"], rows)
        self.assertTrue(rows[-1]["failure"], rows)

    def test_foreign_replays_merged_results_child_hooks_and_unknown_sources_hold(self):
        mutations = (
            (2, ("isReplay",), 1), (2, ("uuid",), SECOND),
            (2, ("session_id",), "foreign"), (2, ("parent_tool_use_id",), "child"),
            (2, ("message", "content"), "different"),
            (3, ("request", "input", "source"), "system"),
            (3, ("request", "input", "agent_id"), "child"),
            (3, ("request", "input", "cwd"), "/foreign"),
            (3, ("request", "input", "prompt_id"), ""),
            (7, ("request", "input", "prompt_id"), SECOND_PROMPT_ID),
            (7, ("request", "input", "background_tasks"), None),
            (7, ("request", "input", "session_crons"), [{}]),
            (7, ("request", "input", "stop_hook_active"), True),
            (10, ("outcome",), "cancelled"), (10, ("outcome",), "error"),
            (11, ("user_message_uuids",), [INPUT, SECOND]),
            (11, ("user_message_uuid",), SECOND), (11, ("is_error",), 0),
            (11, ("queued_turn_count",), True), (11, ("queued_turn_count",), 1),
        )
        for index, path, replacement in mutations:
            with self.subTest(index=index, path=path, replacement=replacement):
                actions = turn()
                target = actions[index]["event"]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_result_does_not_settle_pending_callbacks_and_early_idle_taints(self):
        actions = turn()
        actions.insert(9, actions.pop(11))
        self.assertTrue(self.run_ledger(actions)[-1]["complete"])
        actions = turn()
        actions.insert(9, actions.pop())
        rows = self.run_ledger(actions)
        self.assertFalse(rows[-1]["complete"], rows)
        self.assertTrue(rows[-1]["failure"], rows)

    def test_extra_lifecycles_and_late_prior_ids_cannot_attach_to_a_new_turn(self):
        for extra in (
            lifecycle("Stop", "extra-stop", "hook_started"),
            lifecycle("Stop", "life-stop-A", "hook_response"),
            hook("Stop", "extra-stop-request"),
        ):
            actions = turn() + [begin(SECOND), written(SECOND), extra]
            rows = self.run_ledger(actions)
            self.assertFalse(rows[-1]["complete"], rows)
        actions = turn()
        actions.insert(10, lifecycle("Stop", "extra-stop", "hook_started"))
        rows = self.run_ledger(actions)
        self.assertTrue(rows[-1]["failure"], rows)

    def test_unknown_work_or_cancellation_never_becomes_empty_by_silence(self):
        for extra in (
            event("control_cancel_request", request_id="stop-A"),
            event("control_request", request_id="foreign", request={"subtype": "background_tasks"}),
            event("system", uuid=str(uuid.uuid4()), session_id=SESSION, subtype="background_tasks_changed"),
        ):
            actions = turn()
            actions.insert(10, extra)
            rows = self.run_ledger(actions)
            self.assertFalse(rows[-1]["complete"], rows)
            self.assertTrue(rows[-1]["failure"], rows)
        actions = turn()
        actions.insert(7, {"op": "beginWork", "workID": "command-A"})
        rows = self.run_ledger(actions)
        self.assertFalse(rows[-1]["complete"], rows)
        self.assertGreater(rows[-1]["outstanding"], 0)

    def test_successful_host_work_requires_a_fresh_idle_after_its_actual_settlement(self):
        actions = turn()
        actions.insert(7, {"op": "beginWork", "workID": "command-A"})
        actions.insert(12, {"op": "finishWork", "workID": "command-A"})
        rows = self.run_ledger(actions)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[-1]["outstanding"], 0)

    def test_duplicates_and_mismatched_host_receipts_are_permanent_holds(self):
        for extra in (
            written(SECOND), written(),
            callback_written("foreign-request"),
            {"op": "finishWork", "workID": "unstarted-command"},
        ):
            actions = turn()
            actions.insert(7, extra)
            rows = self.run_ledger(actions)
            self.assertFalse(rows[-1]["complete"], rows)
            self.assertTrue(rows[-1]["failure"], rows)
        for index in (2, 3, 4, 5, 6, 7, 8, 9, 10, 11):
            with self.subTest(index=index):
                actions = turn()
                actions.insert(index + 1, actions[index])
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_absent_inventories_and_unknown_control_fields_are_not_empty(self):
        for index, path in (
            (7, ("request", "input", "background_tasks")),
            (7, ("request", "input", "session_crons")),
            (3, ("request", "input", "source")),
            (3, ("request", "input", "prompt_id")),
            (11, ("user_message_uuids",)), (11, ("queued_turn_count",)),
        ):
            with self.subTest(index=index, path=path):
                actions = turn()
                target = actions[index]["event"]
                for key in path[:-1]:
                    target = target[key]
                del target[path[-1]]
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)
        for path, replacement in (
            (("request", "tool_use_id"), "child"),
            (("request", "input", "unknown_capability"), []),
            (("request", "input", "agent_id"), None),
        ):
            with self.subTest(path=path):
                actions = turn()
                target = actions[3]["event"]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_foreign_root_metadata_and_unsuccessful_hook_exit_cannot_disappear_in_extra_fields(self):
        for index, key, value in (
            (11, "parent_tool_use_id", "child"), (11, "parent_tool_use_id", None),
            (10, "exit_code", 1), (10, "exit_code", True),
            (10, "unknown_capability", []),
            (12, "state", "requires_action"),
        ):
            with self.subTest(index=index, key=key, value=value):
                actions = turn()
                actions[index]["event"][key] = value
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-1]["complete"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_actual_native_writer_refusal_cannot_admit_input_or_settle_a_callback(self):
        for index in (1, 5, 9):
            with self.subTest(index=index):
                actions = turn()
                actions[index]["refuseWrite"] = True
                rows = self.run_ledger(actions)
                self.assertFalse(rows[index]["accepted"], rows)
                self.assertFalse(rows[-1]["complete"], rows)

    def test_partial_raw_activity_revokes_completion_separately_and_in_the_idle_batch(self):
        for coalesced in (False, True):
            with self.subTest(coalesced=coalesced):
                actions = turn()
                if coalesced:
                    data = json.dumps(actions.pop()["event"]).encode() + b"\n{"
                else:
                    data = b"{"
                actions += [{"op": "raw", "bytes": base64.b64encode(data).decode()}, begin(SECOND)]
                rows = self.run_ledger(actions)
                self.assertFalse(rows[-2]["complete"], rows)
                self.assertFalse(rows[-1]["accepted"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_idle_cannot_hide_foreign_attribution_or_unknown_activity_fields(self):
        for key, value in (
            ("parent_tool_use_id", "foreign-tool"), ("parent_tool_use_id", None),
            ("origin", {"type": "system"}), ("unknown_capability", []),
        ):
            with self.subTest(key=key, value=value):
                actions = turn()
                actions[-1]["event"][key] = value
                rows = self.run_ledger(actions + [begin(SECOND)])
                self.assertFalse(rows[-2]["complete"], rows)
                self.assertFalse(rows[-1]["accepted"], rows)
                self.assertTrue(rows[-1]["failure"], rows)

    def test_legitimate_fragmented_idle_completes_only_at_lf_and_empty_reads_do_not_revoke_it(self):
        actions = turn()
        data = json.dumps(actions.pop()["event"]).encode() + b"\n"
        actions += [{"op": "raw", "bytes": base64.b64encode(bytes([byte])).decode()} for byte in data]
        actions += [{"op": "raw", "bytes": ""}]
        rows = self.run_ledger(actions)
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertFalse(any(row["complete"] for row in rows[:-2]), rows)
        self.assertTrue(rows[-2]["complete"], rows)
        self.assertTrue(rows[-1]["complete"], rows)

    def test_coalesced_result_and_idle_preserve_order_without_a_false_pending_suffix(self):
        actions = turn()
        data = b"".join(json.dumps(action["event"]).encode() + b"\n" for action in actions[-2:])
        actions = actions[:-2] + [{"op": "raw", "bytes": base64.b64encode(data).decode()}]
        self.assertTrue(self.run_ledger(actions)[-1]["complete"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
