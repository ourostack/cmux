"""Conditional native Codex root/callback ledger, not effective-profile or runtime qualification."""

import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
INPUT = "11111111-1111-4111-8111-111111111111"
SECOND = "22222222-2222-4222-8222-222222222222"
THREAD = "controlled-thread"
TURN = "provider-turn-A"
PROMPT = "Owner input: 雪 🐈\n/compact and $literal"
COMMAND = {"program": "/bin/echo", "arguments": ["controlled"]}
RESULT = "controlled result"


def rpc_id(input_id=INPUT):
    return "cmux-turn-" + input_id


def begin(input_id=INPUT, origin="owner", prompt=PROMPT):
    return {"op": "begin", "inputID": input_id, "origin": origin, "prompt": prompt}


def written(input_id=INPUT, **fields):
    return {"op": "written", "inputID": input_id, **fields}


def message(value):
    return {"op": "message", "message": value}


def turn_value(turn=TURN, status="inProgress"):
    return {"id": turn, "items": [], "itemsView": "notLoaded", "status": status,
            "error": None, "startedAt": None, "completedAt": None, "durationMs": None}


def acknowledge(input_id=INPUT, turn=TURN):
    return message({"id": rpc_id(input_id), "result": {"turn": turn_value(turn)}})


def lifecycle(method, turn=TURN, thread=THREAD, status=None, summary=None):
    value = turn_value(turn, status or ("completed" if method == "turn/completed" else "inProgress"))
    if summary is not None:
        value.update(items=[summary], itemsView="summary")
    return message({"method": method, "params": {
        "threadId": thread, "turn": value,
    }})


def item_event(method, item, turn=TURN, thread=THREAD):
    timestamp = "startedAtMs" if method == "item/started" else "completedAtMs"
    return message({"method": method, "params": {
        "threadId": thread, "turnId": turn, timestamp: 1, "item": item,
    }})


def tool_item(call="call-A", status="inProgress", content=None, success=None, arguments=None):
    return {"type": "dynamicToolCall", "id": call, "namespace": None, "tool": "cmux_run_foreground",
            "arguments": arguments or COMMAND, "status": status,
            "contentItems": content, "success": success, "durationMs": None}


def tool_request(outer="outer-A", call="call-A", arguments=None, **fields):
    return message({"id": outer, "method": "item/tool/call", "params": {
        "threadId": THREAD, "turnId": TURN, "callId": call, "namespace": None,
        "tool": "cmux_run_foreground", "arguments": arguments or COMMAND, **fields,
    }})


def content(text=RESULT):
    return [{"type": "inputText", "text": text}]


def callback_completed(call="call-A", text=RESULT, success=True, echo=False):
    event = item_event("item/completed", tool_item(
        call, "completed" if success else "failed", content(text), success))
    if echo:
        event["echoCallID"] = call
    return event


def inspection():
    return [{"op": "inspect"}, {"op": "inspectionWritten"},
            {"op": "inspectionResponse", "result": {"data": [], "nextCursor": None}}]


def root_start(input_id=INPUT, turn=TURN):
    return [begin(input_id), written(input_id), acknowledge(input_id, turn), lifecycle("turn/started", turn)]


def simple_turn(input_id=INPUT, turn=TURN):
    return root_start(input_id, turn) + [lifecycle("turn/completed", turn)] + inspection()


def coding_turn(success=True):
    return root_start() + [
        item_event("item/started", tool_item()), tool_request(),
        {"op": "dispatch", "callID": "call-A"},
        {"op": "commandCompleted", "callID": "call-A", "text": RESULT, "success": success},
        {"op": "callbackWritten", "callID": "call-A"}, callback_completed(success=success, echo=True),
        lifecycle("turn/completed"),
    ] + inspection()


class ManagedCodexTurnLedgerTests(unittest.TestCase):
    maxDiff = 1200

    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-codex-turn-ledger-source-"))
        print(f"Retained exact-source Codex ledger build: {cls.build}", file=sys.stderr)
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
                     *(str(ROOT / "Sources/Panels" / name) for name in (
                         "AgentSessionManagedJSON.swift", "AgentSessionManagedCommand.swift",
                         "CodexManagedStreamDecoder.swift", "CodexManagedShellInventory.swift",
                         "CodexManagedTurnLedger.swift")),
                     str(ROOT / "scripts/tests/fixtures/managed_codex_turn_ledger_main.swift"),
                     "-o", str(cls.build / "ledger")],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "ledger"

    def run_ledger(self, actions, coding=True):
        actions = [{**action, "wire": json.dumps(action["message"], ensure_ascii=False,
                                                separators=(",", ":")) + "\n"}
                   if action.get("op") == "message" else action for action in actions]
        result = subprocess.run([str(self.executable)], input=json.dumps({"coding": coding, "actions": actions}),
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_held(self, actions, **options):
        rows = self.run_ledger(actions, **options)
        self.assertFalse(rows[-1]["complete"], rows[-1])
        self.assertNotEqual(rows[-1]["failure"], "", rows[-1])

    def test_exact_root_and_complete_empty_shell_snapshot_are_all_required(self):
        rows = self.run_ledger(simple_turn())
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertFalse(any(row["complete"] for row in rows[:-1]), rows)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[-1]["outstanding"], 0)

    def test_outgoing_native_frame_is_literal_text_without_runtime_override_fields(self):
        row = self.run_ledger([begin()])[0]
        self.assertEqual(row["frame"], {"id": rpc_id(), "method": "turn/start", "params": {
            "threadId": THREAD, "input": [{"type": "text", "text": PROMPT, "text_elements": []}],
        }})

    def test_real_pipe_write_and_matching_rpc_reply_are_separate_facts(self):
        actions = [begin(), acknowledge(), lifecycle("turn/started"), lifecycle("turn/completed")]
        rows = self.run_ledger(actions)
        self.assertFalse(any(row["complete"] for row in rows), rows)
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)
        rows = self.run_ledger(actions + [written()] + inspection())
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[-1]["lookup"], INPUT)
        rows = self.run_ledger([begin(), written(refuseWrite=True), acknowledge(),
                                lifecycle("turn/started"), lifecycle("turn/completed")])
        self.assertFalse(any(row["complete"] for row in rows), rows)

    def test_provider_turn_id_is_returned_and_mapped_not_assumed_equal_to_host_uuid(self):
        rows = self.run_ledger(simple_turn())
        self.assertEqual(rows[-1]["lookup"], INPUT)
        self.assertNotEqual(TURN, INPUT)

    def test_foreign_rpc_thread_turn_duplicate_reply_and_item_alias_never_complete_root(self):
        for invalid in (
            message({"id": "foreign", "result": {"turn": turn_value()}}),
            message({"id": rpc_id(), "error": {"code": -1, "message": "failed"}}),
        ):
            self.assert_held([begin(), written(), invalid])
        self.assert_held(root_start() + [acknowledge()])
        self.assert_held(root_start() + [lifecycle("turn/completed", thread="foreign")])
        self.assert_held(root_start() + [lifecycle("turn/completed", turn="foreign")])
        self.assert_held(root_start() + [message({"method": "item-message/completed",
                                                "params": {"threadId": THREAD, "turnId": TURN}})])

    def test_failed_interrupted_or_error_bearing_root_is_never_success(self):
        for status in ("failed", "interrupted", "inProgress"):
            self.assert_held(root_start() + [lifecycle("turn/completed", status=status)])
        event = lifecycle("turn/completed")
        event["message"]["params"]["turn"]["error"] = {"message": "failed"}
        self.assert_held(root_start() + [event])
        self.assert_held([begin(), written(), acknowledge(), lifecycle("turn/completed")])

    def test_root_done_does_not_close_unknown_or_later_autonomous_work(self):
        self.assert_held(simple_turn() + [lifecycle("turn/started", turn="queued-autonomous")])
        self.assert_held(simple_turn() + [lifecycle("turn/completed")])
        self.assert_held(root_start() + [message({"method": "thread/realtime/started", "params": {}})])

    def test_partial_ingress_immediately_revokes_work_evidence_and_native_revision(self):
        rows = self.run_ledger(simple_turn() + [{"op": "raw", "bytes": base64.b64encode(b'{"method":').decode()}])
        self.assertTrue(rows[-2]["complete"], rows[-2])
        self.assertFalse(rows[-1]["complete"], rows[-1])
        self.assertNotEqual(rows[-1]["revision"], rows[-2]["revision"])
        self.assertGreater(rows[-1]["outstanding"], 0)
        self.assert_held(simple_turn() + [{"op": "raw", "bytes": base64.b64encode(b'{"method":').decode()},
                                        {"op": "eof"}])

    def test_second_input_requires_complete_prior_evidence_and_cannot_reuse_turn_ids(self):
        rows = self.run_ledger(root_start() + [begin(SECOND)])
        self.assertFalse(rows[-1]["accepted"], rows)
        self.assertEqual(rows[-1]["failure"], "")
        rows = self.run_ledger(simple_turn() + simple_turn(SECOND, "provider-turn-B"))
        self.assertTrue(rows[-1]["complete"], rows)
        self.assert_held(simple_turn() + [begin(SECOND), written(SECOND), acknowledge(SECOND)])

    def test_exact_foreground_callback_requires_native_work_and_consumed_result(self):
        rows = self.run_ledger(coding_turn())
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertTrue(rows[-1]["complete"], rows)
        frame = next(row["frame"] for row in rows if row["frame"].get("result", {}).get("contentItems"))
        text = frame["result"]["contentItems"][0]["text"]
        self.assertRegex(text, r"^cmux-owned-result:[0-9a-f-]{36}\n")
        self.assertEqual(text.split("\n", 1)[1], RESULT)
        self.assertEqual(frame, {"id": "outer-A", "result": {"contentItems": content(text), "success": True}})
        self.assertFalse(any(row["complete"] for row in rows[:-1]), rows)

    def test_callback_write_is_not_consumption_and_exact_early_consumption_waits_for_full_write(self):
        actions = coding_turn()
        write_index = next(i for i, action in enumerate(actions) if action["op"] == "callbackWritten")
        consumed_index = next(i for i, action in enumerate(actions)
                              if action.get("message", {}).get("method") == "item/completed")
        without_consumption = [action for index, action in enumerate(actions[:11]) if index != consumed_index]
        self.assert_held(without_consumption)
        early = actions[:write_index] + [actions[consumed_index], lifecycle("turn/completed"),
                                        actions[write_index]] + inspection()
        rows = self.run_ledger(early)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertFalse(any(row["complete"] for row in rows[:-1]), rows)

    def test_wrong_call_arguments_content_success_or_foreign_callback_cannot_discharge_work(self):
        prefix = coding_turn()[:8]
        for event in (
            callback_completed(call="foreign"),
            callback_completed(text="foreign result"),
            callback_completed(success=False, echo=True),
            item_event("item/completed", tool_item(
                status="completed", content=content(), success=True,
                arguments={"program": "/bin/echo", "arguments": ["foreign"]})),
        ):
            with self.subTest(event=event):
                self.assert_held(prefix + [event])

    def test_a_known_complete_failed_command_is_consumed_but_not_confused_with_unknown_work(self):
        rows = self.run_ledger(coding_turn(success=False))
        self.assertTrue(rows[-1]["complete"], rows)
        self.assert_held(root_start() + [item_event("item/started", tool_item()), tool_request(),
                                        {"op": "commandCompleted", "callID": "call-A",
                                         "text": RESULT, "success": True}])

    def test_unmatched_or_disabled_tool_requests_are_held_before_native_dispatch(self):
        self.assert_held(root_start() + [tool_request()])
        self.assert_held(root_start() + [item_event("item/started", tool_item())], coding=False)
        for extra in ({"cwd": "/foreign"}, {"background": True}, {"timeout": 100}):
            args = {**COMMAND, **extra}
            self.assert_held(root_start() + [item_event("item/started", tool_item(arguments=args))])
        self.assert_held(root_start() + [item_event("item/started", tool_item()),
                                        tool_request(outer=7), tool_request(outer="7")])

    def test_partial_shell_pages_or_empty_reply_without_write_never_establish_coverage(self):
        prefix = root_start() + [lifecycle("turn/completed"), {"op": "inspect"}, {"op": "inspectionWritten"},
                                {"op": "inspectionResponse", "result": {"data": [], "nextCursor": "next"}}]
        rows = self.run_ledger(prefix)
        self.assertFalse(any(row["complete"] for row in rows), rows)
        rows = self.run_ledger(prefix + [{"op": "inspect"}, {"op": "inspectionResponse",
                                                        "result": {"data": [], "nextCursor": None}}])
        self.assertFalse(rows[-1]["complete"], rows)
        rows = self.run_ledger(prefix + [{"op": "inspect"}, {"op": "inspectionWritten"},
                                        {"op": "inspectionResponse",
                                         "result": {"data": [], "nextCursor": None}}])
        self.assertTrue(rows[-1]["complete"], rows)

    def test_background_shell_or_activity_during_inspection_is_not_a_clean_snapshot(self):
        record = {"itemId": "item-X", "processId": "process-X", "command": "foreign",
                  "cwd": "/foreign", "osPid": None, "cpuPercent": None, "rssKb": None}
        self.assert_held(root_start() + [lifecycle("turn/completed"), {"op": "inspect"},
                                        {"op": "inspectionWritten"}, {"op": "inspectionResponse",
                                                                     "result": {"data": [record], "nextCursor": None}}])
        self.assert_held(root_start() + [lifecycle("turn/completed"), {"op": "inspect"},
                                        lifecycle("turn/started", turn="late")])

    def test_passive_message_lifecycles_are_bound_and_do_not_replace_root_completion(self):
        started = {"type": "agentMessage", "id": "message-A", "text": "", "phase": None,
                   "memoryCitation": None, "delivery": None, "questions": None}
        ended = {**started, "text": "controlled answer"}
        actions = root_start() + [item_event("item/started", started),
                                  message({"method": "item/agentMessage/delta", "params": {
                                      "threadId": THREAD, "turnId": TURN, "itemId": "message-A",
                                      "delta": "controlled answer"}}), item_event("item/completed", ended)]
        rows = self.run_ledger(actions)
        self.assertFalse(any(row["complete"] for row in rows), rows)
        self.assertTrue(self.run_ledger(actions + [lifecycle("turn/completed", summary=ended)] + inspection())[-1]["complete"])
        self.assert_held(root_start() + [item_event("item/completed", ended)])
        self.assert_held(root_start() + [item_event("item/started", {**started, "questions": []})])

    def test_eof_and_unexpected_permission_requests_are_sticky_barriers(self):
        self.assert_held(simple_turn() + [{"op": "eof"}])
        self.assert_held(root_start() + [message({"id": 99, "method": "item/commandExecution/requestApproval",
                                                "params": {"threadId": THREAD, "turnId": TURN}})])

    def test_malformed_passive_metadata_cannot_still_produce_positive_work_evidence(self):
        base = {"type": "agentMessage", "id": "message-A", "text": "controlled",
                "phase": None, "memoryCitation": None, "delivery": None, "questions": None}
        for extra in (
            {"phase": True}, {"phase": 7}, {"phase": []}, {"phase": {}},
            {"phase": "finalAnswer"}, {"phase": "background"},
            {"memoryCitation": True}, {"memoryCitation": 7},
            {"memoryCitation": "not-an-object"}, {"memoryCitation": []},
            {"memoryCitation": {}}, {"memoryCitation": {"entries": [], "rolloutIds": []}},
            {"memoryCitation": {"entries": [], "threadIds": [7]}},
            *({"memoryCitation": {"entries": [{
                "path": "untrusted", "lineStart": number, "lineEnd": 1, "note": "untrusted",
            }], "threadIds": []}} for number in (True, 1.0, -1, 2**32)),
        ):
            item = {**base, **extra}
            with self.subTest(extra=extra):
                rows = self.run_ledger(root_start() + [
                    item_event("item/started", item), item_event("item/completed", item),
                    lifecycle("turn/completed"),
                ] + inspection())
                self.assertFalse(rows[-1]["complete"], rows[-1])
                self.assertNotEqual(rows[-1]["failure"], "", rows[-1])

    def test_valid_final_answer_phase_and_citations_remain_passive_not_root_completion(self):
        for phase in (None, "commentary", "final_answer"):
            item = {"type": "agentMessage", "id": "message-A", "text": "controlled",
                    "phase": phase, "memoryCitation": {
                        "entries": [{"path": "untrusted-path", "lineStart": 0,
                                     "lineEnd": 2**32-1, "note": "untrusted citation"}],
                        "threadIds": ["a-citation-is-not-an-agent-or-a-root"],
                    }, "delivery": None, "questions": None}
            actions = root_start() + [item_event("item/started", item), item_event("item/completed", item)]
            with self.subTest(phase=phase):
                rows = self.run_ledger(actions)
                self.assertTrue(all(row["failure"] == "" for row in rows), rows)
                self.assertFalse(any(row["complete"] for row in rows), rows)
                summary = item if phase in (None, "final_answer") else None
                self.assertTrue(self.run_ledger(actions + [lifecycle("turn/completed", summary=summary)] + inspection())[-1]["complete"])

    def test_backend_fallback_cannot_impersonate_consumption_of_an_identical_failed_command(self):
        for fallback in ("dynamic tool request failed", "dynamic tool response was invalid"):
            actions = root_start() + [
                item_event("item/started", tool_item()), tool_request(),
                {"op": "dispatch", "callID": "call-A"},
                {"op": "commandCompleted", "callID": "call-A", "text": fallback, "success": False},
                {"op": "callbackWritten", "callID": "call-A"},
                callback_completed(text=fallback, success=False),
                lifecycle("turn/completed"),
            ] + inspection()
            with self.subTest(fallback=fallback):
                self.assert_held(actions)
                actions[9]["echoCallID"] = "call-A"
                self.assertTrue(self.run_ledger(actions)[-1]["complete"])

    def test_callback_result_witness_is_unique_and_cannot_be_replayed_between_identical_commands(self):
        actions = root_start()
        for suffix in ("A", "B"):
            call = "call-" + suffix
            actions.extend([
                item_event("item/started", tool_item(call)), tool_request("outer-" + suffix, call),
                {"op": "dispatch", "callID": call},
                {"op": "commandCompleted", "callID": call, "text": RESULT, "success": True},
                {"op": "callbackWritten", "callID": call}, callback_completed(call, echo=True),
            ])
        complete = actions + [lifecycle("turn/completed")] + inspection()
        rows = self.run_ledger(complete)
        self.assertTrue(rows[-1]["complete"], rows[-1])
        frames = [row["frame"]["result"]["contentItems"][0]["text"] for row in rows
                  if row["frame"].get("result", {}).get("contentItems")]
        self.assertEqual(len(frames), 2)
        self.assertNotEqual(frames[0].split("\n", 1)[0], frames[1].split("\n", 1)[0])
        self.assertTrue(all(value.split("\n", 1)[1] == RESULT for value in frames))
        complete[-5]["echoCallID"] = "call-A"
        self.assert_held(complete)

    def test_pinned_reasoning_progress_is_passive_and_bound_to_its_live_root_item(self):
        item = {"type": "reasoning", "id": "reasoning-A", "summary": [], "content": []}
        common = {"threadId": THREAD, "turnId": TURN, "itemId": "reasoning-A"}
        actions = root_start() + [
            item_event("item/started", item),
            message({"method": "item/reasoning/summaryPartAdded", "params": {**common, "summaryIndex": 0}}),
            message({"method": "item/reasoning/summaryTextDelta",
                     "params": {**common, "summaryIndex": 0, "delta": "controlled summary"}}),
            message({"method": "item/reasoning/textDelta",
                     "params": {**common, "contentIndex": 0, "delta": "controlled content"}}),
            item_event("item/completed", {**item, "summary": ["controlled summary"],
                                         "content": ["controlled content"]}),
        ]
        rows = self.run_ledger(actions)
        self.assertTrue(all(row["accepted"] and row["failure"] == "" for row in rows), rows)
        self.assertFalse(any(row["complete"] for row in rows), rows)
        self.assertTrue(self.run_ledger(actions + [lifecycle("turn/completed")] + inspection())[-1]["complete"])

    def test_reasoning_progress_rejects_foreign_closed_or_malformed_indices(self):
        item = {"type": "reasoning", "id": "reasoning-A", "summary": [], "content": []}
        prefix = root_start() + [item_event("item/started", item)]
        common = {"threadId": THREAD, "turnId": TURN, "itemId": "reasoning-A", "delta": "controlled"}
        for extra in ({"summaryIndex": True}, {"summaryIndex": 1.0}, {"summaryIndex": -1},
                      {"summaryIndex": 0, "itemId": "foreign"},
                      {"summaryIndex": 0, "threadId": "foreign"},
                      {"summaryIndex": 0, "turnId": "foreign"}):
            self.assert_held(prefix + [message({"method": "item/reasoning/summaryTextDelta",
                                              "params": {**common, **extra}})])
        self.assert_held(prefix + [item_event("item/completed", item), message({
            "method": "item/reasoning/textDelta", "params": {**common, "contentIndex": 0},
        })])

    def test_known_queued_callbacks_do_not_overlap_the_kept_native_command_service(self):
        actions = root_start() + [
            item_event("item/started", tool_item("call-A")), tool_request("outer-A", "call-A"),
            item_event("item/started", tool_item("call-B")), tool_request("outer-B", "call-B"),
            {"op": "dispatch", "callID": "call-A"},
        ]
        rows = self.run_ledger(actions)
        self.assertEqual(rows[-1]["nextCallback"], "", rows[-1])
        rows = self.run_ledger(actions + [{"op": "dispatch", "callID": "call-B"}])
        self.assertFalse(rows[-1]["accepted"], rows[-1])
        self.assertEqual(rows[-1]["failure"], "", rows[-1])
        actions.extend([
            {"op": "commandCompleted", "callID": "call-A", "text": RESULT, "success": True},
            {"op": "callbackWritten", "callID": "call-A"}, callback_completed("call-A", echo=True),
            {"op": "dispatch", "callID": "call-B"},
            {"op": "commandCompleted", "callID": "call-B", "text": RESULT, "success": True},
            {"op": "callbackWritten", "callID": "call-B"}, callback_completed("call-B", echo=True),
            lifecycle("turn/completed"),
        ])
        self.assertTrue(self.run_ledger(actions + inspection())[-1]["complete"])

    def test_owner_prompt_limit_counts_exact_utf8_bytes_without_clipping_or_rewriting(self):
        for prompt in ("x" * 65_536, "雪" * 21_845 + "x"):
            with self.subTest(bytes=len(prompt.encode())):
                row = self.run_ledger([begin(prompt=prompt)])[0]
                self.assertTrue(row["accepted"], row["failure"])
                self.assertEqual(row["frame"]["params"]["input"][0]["text"], prompt)
                row = self.run_ledger([begin(prompt=prompt + "x")])[0]
                self.assertFalse(row["accepted"], row["failure"])
                self.assertEqual(row["failure"], "invalidInput")

    def test_early_event_buffer_accepts_64_messages_and_holds_before_the_65th(self):
        events = [lifecycle("turn/started")]
        for index in range(63):
            events.append(item_event("item/started", {"type": "plan", "id": f"early-{index}", "text": ""}))
        rows = self.run_ledger([begin()] + events)
        self.assertTrue(all(row["accepted"] and row["failure"] == "" for row in rows), rows[-1])
        self.assertFalse(any(row["complete"] for row in rows), rows[-1])
        self.assert_held([begin()] + events + [item_event("item/started", {
            "type": "plan", "id": "over-limit", "text": "",
        })])

    def test_live_item_limit_is_inclusive_and_does_not_evict_work_to_make_room(self):
        actions = root_start() + [item_event("item/started", {
            "type": "plan", "id": f"item-{index}", "text": "",
        }) for index in range(256)]
        rows = self.run_ledger(actions)
        self.assertEqual(rows[-1]["failure"], "")
        self.assertEqual(rows[-1]["outstanding"], 256)
        self.assert_held(actions + [item_event("item/started", {
            "type": "plan", "id": "over-limit", "text": "",
        })])

    def test_result_text_limit_is_inclusive_and_overflow_remains_outstanding(self):
        prefix = root_start() + [item_event("item/started", tool_item()), tool_request(),
                                 {"op": "dispatch", "callID": "call-A"}]
        rows = self.run_ledger(prefix + [{
            "op": "commandCompleted", "callID": "call-A", "text": "x" * 262_144, "success": True,
        }])
        text = rows[-1]["frame"]["result"]["contentItems"][0]["text"]
        self.assertEqual(len(text.split("\n", 1)[1]), 262_144)
        self.assertEqual(rows[-1]["failure"], "")
        self.assertFalse(rows[-1]["complete"])
        rows = self.run_ledger(prefix + [{
            "op": "commandCompleted", "callID": "call-A", "text": "x" * 262_145, "success": True,
        }])
        self.assertEqual(rows[-1]["failure"], "commandCompletionMismatch")
        self.assertGreater(rows[-1]["outstanding"], 0)
        self.assertFalse(rows[-1]["complete"])

    def test_early_byte_limit_uses_actual_wire_bytes_and_is_inclusive(self):
        def wire_size(action):
            return len(json.dumps(action["message"], ensure_ascii=False, separators=(",", ":")).encode()) + 1
        first = lifecycle("turn/started")
        second = item_event("item/started", {"type": "plan", "id": "large-early", "text": ""})
        second["message"]["params"]["item"]["text"] = "x" * (1_048_576 - wire_size(first) - wire_size(second))
        self.assertEqual(wire_size(first) + wire_size(second), 1_048_576)
        rows = self.run_ledger([begin(), first, second])
        self.assertEqual(rows[-1]["failure"], "", rows[-1])
        self.assertFalse(rows[-1]["complete"])
        rows = self.run_ledger([begin(), first, second, lifecycle("turn/started")])
        self.assertEqual(rows[-1]["failure"], "earlyEventOverflow", rows[-1])
        self.assertFalse(rows[-1]["complete"])

    def test_root_ingress_limit_is_exact_and_overflow_is_not_just_incomplete_json(self):
        def wire_size(action):
            return len(json.dumps(action["message"], ensure_ascii=False, separators=(",", ":")).encode()) + 1
        actions = root_start() + [item_event("item/started", {"type": "plan", "id": "plan-A", "text": ""})]
        used = sum(wire_size(action) for action in actions if "message" in action)

        def delta(text):
            return message({"method": "item/plan/delta", "params": {
                "threadId": THREAD, "turnId": TURN, "itemId": "plan-A", "delta": text,
            }})

        overhead = wire_size(delta(""))
        remaining = 8 * 1024 * 1024 - used
        while remaining > 4096:
            actions.append(delta("x" * (4096 - overhead)))
            remaining -= 4096
        if 0 < remaining < overhead:
            actions[-1]["message"]["params"]["delta"] = actions[-1]["message"]["params"]["delta"][:-overhead]
            remaining += overhead
        if remaining:
            actions.append(delta("x" * (remaining - overhead)))
        self.assertEqual(sum(wire_size(action) for action in actions if "message" in action), 8 * 1024 * 1024)
        rows = self.run_ledger(actions + [{"op": "raw", "bytes": base64.b64encode(b" ").decode()}])
        self.assertEqual(rows[-2]["failure"], "", rows[-2])
        self.assertEqual(rows[-1]["failure"], "unexpectedIngress", rows[-1])
        self.assertFalse(any(row["complete"] for row in rows), rows[-1])

    def test_canonical_terminal_summary_matches_the_completed_final_item_and_is_not_new_work(self):
        item = {"type": "agentMessage", "id": "final-A", "text": "controlled final answer",
                "phase": "final_answer", "memoryCitation": None, "delivery": None, "questions": None}
        actions = root_start() + [item_event("item/started", item), item_event("item/completed", item),
                                  lifecycle("turn/completed", summary=item)]
        rows = self.run_ledger(actions + inspection())
        self.assertTrue(all(row["accepted"] for row in rows), rows[-1])
        self.assertTrue(rows[-1]["complete"], rows[-1])
        self.assertEqual(rows[-1]["outstanding"], 0)

    def test_terminal_summary_never_creates_an_unseen_item_or_discharges_outstanding_work(self):
        item = {"type": "agentMessage", "id": "final-A", "text": "controlled final answer",
                "phase": "final_answer", "memoryCitation": None, "delivery": None, "questions": None}
        prefix = root_start() + [item_event("item/started", item), item_event("item/completed", item)]
        for summary in ({**item, "id": "foreign"}, {**item, "text": "foreign"},
                        {**item, "phase": True}, tool_item()):
            with self.subTest(summary=summary):
                self.assert_held(prefix + [lifecycle("turn/completed", summary=summary)])
        self.assert_held(root_start() + [lifecycle("turn/completed", summary=item)])
        self.assert_held(prefix + [item_event("item/started", tool_item()), tool_request(),
                                   lifecycle("turn/completed", summary=item)])
        self.assert_held(prefix + [lifecycle("turn/started", summary=item)])

    def test_terminal_summary_selects_the_last_eligible_final_or_legacy_message_not_commentary(self):
        first = {"type": "agentMessage", "id": "final-A", "text": "first",
                 "phase": "final_answer", "memoryCitation": None, "delivery": None, "questions": None}
        for phase in ("commentary", "final_answer", None):
            second = {**first, "id": "message-B", "text": "second", "phase": phase}
            actions = root_start() + [
                item_event("item/started", first), item_event("item/completed", first),
                item_event("item/started", second), item_event("item/completed", second),
            ]
            expected = first if phase == "commentary" else second
            wrong = second if phase == "commentary" else first
            with self.subTest(phase=phase):
                self.assertTrue(self.run_ledger(actions + [
                    lifecycle("turn/completed", summary=expected),
                ] + inspection())[-1]["complete"])
                self.assert_held(actions + [lifecycle("turn/completed", summary=wrong)])

    def test_terminal_summary_view_and_cardinality_are_not_a_history_or_work_inventory(self):
        item = {"type": "agentMessage", "id": "final-A", "text": "controlled",
                "phase": None, "memoryCitation": None, "delivery": None, "questions": None}
        prefix = root_start() + [item_event("item/started", item), item_event("item/completed", item)]
        for view, items in (("summary", []), ("summary", [item, item]),
                            ("full", [item]), ("notLoaded", [item]), ("notLoaded", [])):
            event = lifecycle("turn/completed")
            event["message"]["params"]["turn"].update(itemsView=view, items=items)
            with self.subTest(view=view, count=len(items)):
                self.assert_held(prefix + [event])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
