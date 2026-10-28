"""Actual bounded shell pagination, never a total-work or provider qualification proof."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
REVISION = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
CHANGED = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


def request(identifier="page-A", **fields):
    return {"op": "request", "id": identifier, "revision": REVISION, **fields}


def written(identifier="page-A", **fields):
    return {"op": "written", "id": identifier, "revision": REVISION, **fields}


def response(identifier="page-A", data=None, cursor=None, **fields):
    return {"op": "response", "message": {"id": identifier, "result": {
        "data": data if data is not None else [], "nextCursor": cursor,
    }}, "revision": REVISION, **fields}


def terminal(item="item-A", process="process-A", **fields):
    return {"itemId": item, "processId": process, "command": "controlled command",
            "cwd": "/controlled-project", "osPid": None, "cpuPercent": None, "rssKb": None, **fields}


class ManagedCodexShellInventoryTests(unittest.TestCase):
    maxDiff = 1000

    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-codex-shell-inventory-source-"))
        print(f"Retained exact-source Codex inventory build: {cls.build}", file=sys.stderr)
        cls.executable = cls.build / "inventory"
        result = subprocess.run([
            "swiftc", "-swift-version", "6", "-gnone", "-parse-as-library",
            "-module-cache-path", str(MODULE_CACHE or cls.build / "cache"),
            str(ROOT / "Sources/Panels/AgentSessionManagedJSON.swift"),
            str(ROOT / "Sources/Panels/CodexManagedStreamDecoder.swift"),
            str(ROOT / "Sources/Panels/CodexManagedShellInventory.swift"),
            str(ROOT / "scripts/tests/fixtures/managed_codex_shell_inventory_main.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_inventory(self, actions):
        actions = [{**action, "wire": json.dumps(action["message"], separators=(",", ":")) + "\n"}
                   if action.get("op") == "response" else action for action in actions]
        result = subprocess.run([str(self.executable)], input=json.dumps(actions),
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_held(self, actions):
        rows = self.run_inventory(actions + [request("after-failure"), written("after-failure")])
        self.assertFalse(any(row["emptyComplete"] for row in rows), rows)
        self.assertNotEqual(rows[-3]["failure"], "", rows)
        self.assertEqual(rows[-3]["failure"], rows[-1]["failure"], rows)
        self.assertFalse(rows[-2]["accepted"], rows)
        self.assertFalse(rows[-1]["accepted"], rows)

    def test_empty_page_is_not_positive_until_exact_full_request_write_and_response(self):
        rows = self.run_inventory([request(), response(), written()])
        self.assertTrue(all(row["accepted"] for row in rows), rows)
        self.assertFalse(any(row["emptyComplete"] for row in rows[:-1]), rows)
        self.assertTrue(rows[-1]["emptyComplete"], rows)
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertEqual(rows[0]["request"], {"id": "page-A", "method": "thread/backgroundTerminals/list",
                                             "params": {"threadId": "thread-A", "cursor": None, "limit": 128}})

    def test_written_request_is_not_a_readback_and_no_page_is_not_an_empty_inventory(self):
        rows = self.run_inventory([{"op": "snapshot"}, request(), written()])
        self.assertFalse(any(row["complete"] or row["emptyComplete"] for row in rows), rows)
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)

    def test_every_cursor_is_visited_before_a_multi_page_empty_inventory_completes(self):
        rows = self.run_inventory([
            request(), written(), response(cursor="opaque-1"),
            request("page-B"), written("page-B"), response("page-B", cursor="opaque-2"),
            request("page-C"), written("page-C"), response("page-C"),
        ])
        self.assertFalse(any(row["complete"] for row in rows[:-1]), rows)
        self.assertTrue(rows[-1]["emptyComplete"], rows)
        self.assertEqual(rows[3]["request"]["params"]["cursor"], "opaque-1")
        self.assertEqual(rows[6]["request"]["params"]["cursor"], "opaque-2")

    def test_nonempty_inventory_is_complete_but_never_reports_empty_work(self):
        entries = [terminal(), terminal("item-B", "process-B", osPid=123, cpuPercent=250.25, rssKb=456)]
        rows = self.run_inventory([
            request(), written(), response(data=[entries[0]], cursor="opaque-1"),
            request("page-B"), written("page-B"), response("page-B", data=[entries[1]]),
        ])
        self.assertTrue(rows[-1]["complete"], rows)
        self.assertFalse(any(row["emptyComplete"] for row in rows), rows)
        self.assertEqual(rows[-1]["terminals"], entries)

    def test_foreign_error_request_notification_and_duplicate_responses_are_not_pages(self):
        for message in (
            {"id": "foreign", "result": {"data": [], "nextCursor": None}},
            {"id": "page-A", "error": {"code": -1, "message": "failed"}},
            {"id": "page-A", "method": "item/tool/call", "params": {}},
            {"method": "turn/completed", "params": {}},
        ):
            with self.subTest(message=message):
                self.assert_held([request(), written(),
                                  {"op": "response", "message": message, "revision": REVISION}])
        self.assert_held([request(), response(cursor="opaque-1"), response(cursor="opaque-1")])

    def test_revision_change_before_request_write_reply_or_next_page_is_terminal(self):
        for actions in (
            [request(revision=CHANGED)],
            [request(), written(revision=CHANGED)],
            [request(), written(), response(revision=CHANGED)],
            [request(), written(), response(cursor="opaque-1"), request("page-B", revision=CHANGED)],
        ):
            with self.subTest(actions=actions):
                self.assert_held(actions)

    def test_cursor_cycles_empty_malformed_and_oversized_cursors_are_terminal(self):
        for cursor in ("", False, 7, [], {}, "x" * 4097):
            with self.subTest(cursor=cursor):
                self.assert_held([request(), written(), response(cursor=cursor)])
        self.assert_held([
            request(), written(), response(cursor="cycle"),
            request("page-B"), written("page-B"), response("page-B", cursor="cycle"),
        ])

    def test_missing_null_partial_or_unknown_page_shapes_are_not_empty(self):
        for result in (None, {}, {"data": []}, {"nextCursor": None},
                       {"data": None, "nextCursor": None}, {"data": {}, "nextCursor": None},
                       {"data": [], "nextCursor": None, "complete": True}):
            with self.subTest(result=result):
                self.assert_held([request(), written(), {"op": "response",
                                  "message": {"id": "page-A", "result": result}, "revision": REVISION}])

    def test_duplicate_item_or_process_identity_in_one_or_later_pages_is_terminal(self):
        for second in (terminal("item-A", "process-B"), terminal("item-B", "process-A")):
            with self.subTest(second=second):
                self.assert_held([request(), written(), response(data=[terminal(), second])])
                self.assert_held([
                    request(), written(), response(data=[terminal()], cursor="next"),
                    request("page-B"), written("page-B"), response("page-B", data=[second]),
                ])

    def test_partial_malformed_terminal_records_cannot_be_dropped_to_get_empty_success(self):
        invalid = [
            None, {}, {key: value for key, value in terminal().items() if key != "processId"},
            terminal(item=""), terminal(process=""), terminal(command=False), terminal(cwd=False),
            terminal(osPid=True), terminal(osPid=1.0), terminal(osPid=-1), terminal(osPid=2**32),
            terminal(cpuPercent=True), terminal(cpuPercent=-1), terminal(rssKb=True),
            terminal(rssKb=1.0), terminal(rssKb=-1), terminal(rssKb=2**64),
            terminal(extra="unknown"), terminal(command="x" * (256 * 1024 + 1)),
        ]
        for entry in invalid:
            with self.subTest(entry=str(entry)[:150]):
                self.assert_held([request(), written(), response(data=[entry])])

    def test_duplicate_requests_writes_and_request_id_reuse_are_terminal(self):
        self.assert_held([request(), request("page-B")])
        self.assert_held([request(), written(), written()])
        self.assert_held([request(), written(), response(cursor="next"), request()])
        self.assert_held([written()])

    def test_numeric_request_ids_do_not_alias_strings(self):
        self.assert_held([request(7), written(7), response("7")])
        rows = self.run_inventory([
            request(7), written(7), response(7, cursor="next"),
            request("7"), written("7"), response("7"),
        ])
        self.assertTrue(rows[-1]["emptyComplete"], rows)

    def test_page_limit_cannot_return_more_entries_than_requested(self):
        entries = [terminal(f"item-{index}", f"process-{index}") for index in range(129)]
        self.assert_held([request(), written(), response(data=entries)])

    def test_paginated_empty_responses_are_bounded_not_an_unending_positive_probe(self):
        actions = []
        for index in range(64):
            actions.extend([request(f"page-{index}"), written(f"page-{index}"),
                            response(f"page-{index}", cursor=f"cursor-{index}")])
        self.assert_held(actions + [request("over-limit")])

    def test_a_completed_inventory_cannot_be_reopened_or_reused_for_new_work(self):
        rows = self.run_inventory([request(), written(), response(), request("new-inspection")])
        self.assertTrue(rows[-2]["emptyComplete"], rows)
        self.assertFalse(rows[-1]["accepted"], rows)
        self.assertFalse(rows[-1]["emptyComplete"], rows)
        self.assertNotEqual(rows[-1]["failure"], "", rows)

    def test_native_enum_construction_cannot_bypass_bounded_request_identity(self):
        for identifier in ("", "x" * 4097):
            with self.subTest(identifier=identifier[:30]):
                self.assert_held([request(identifier)])

    def test_exact_page_and_terminal_count_limits_are_accepted_before_overflow_is_held(self):
        pages = []
        for index in range(64):
            pages.extend([request(f"page-{index}"), written(f"page-{index}"),
                          response(f"page-{index}", cursor=f"cursor-{index}" if index < 63 else None)])
        rows = self.run_inventory(pages)
        self.assertTrue(rows[-1]["emptyComplete"], rows[-1])
        actions = []
        for index in range(8):
            entries = [terminal(f"item-{index}-{item}", f"process-{index}-{item}") for item in range(128)]
            actions.extend([request(f"page-{index}"), written(f"page-{index}"),
                            response(f"page-{index}", data=entries, cursor=f"cursor-{index}")])
        rows = self.run_inventory(actions)
        self.assertEqual(rows[-1]["terminalCount"], 1024)
        self.assertEqual(rows[-1]["failure"], "")
        self.assert_held(actions + [request("overflow"), written("overflow"),
                                   response("overflow", data=[terminal("extra", "extra")])])

    def test_exact_retained_byte_limit_is_accepted_and_the_next_record_is_held(self):
        entries = [terminal(f"item-{index}", f"process-{index}", command="") for index in range(8)]
        remaining = 2 * 1024 * 1024 - sum(
            sum(len(entry[key].encode()) for key in ("itemId", "processId", "command", "cwd"))
            for entry in entries
        )
        for entry in entries:
            count = min(256 * 1024, remaining)
            entry["command"] = "x" * count
            remaining -= count
        self.assertEqual(remaining, 0)
        actions = []
        for index in range(4):
            actions.extend([request(f"page-{index}"), written(f"page-{index}"),
                            response(f"page-{index}", data=entries[index * 2:(index + 1) * 2],
                                     cursor=f"cursor-{index}")])
        actions = [{**action, "suppressTerminals": True} for action in actions]
        rows = self.run_inventory(actions)
        self.assertEqual(rows[-1]["terminalCount"], 8)
        self.assertEqual(rows[-1]["failure"], "")
        rows = self.run_inventory(actions + [
            request("overflow"), written("overflow"), response("overflow", data=[terminal("extra", "extra")]),
        ])
        self.assertEqual(rows[-1]["failure"], "inventoryTooLarge")
        self.assertFalse(rows[-1]["complete"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
