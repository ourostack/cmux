"""Pinned raw Codex wire frames through OS pipes; no provider or qualification."""

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
LIMIT = 1_048_576


def chunk(data):
    return {"bytes": base64.b64encode(data).decode()}


def wire(message):
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"


class ManagedCodexStreamTests(unittest.TestCase):
    maxDiff = 1000

    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-codex-stream-source-"))
        print(f"Retained exact-source Codex decoder build: {cls.build}", file=sys.stderr)
        cls.executable = cls.build / "decoder"
        result = subprocess.run([
            "swiftc", "-swift-version", "6", "-gnone", "-parse-as-library",
            "-module-cache-path", str(MODULE_CACHE or cls.build / "cache"),
            str(ROOT / "Sources/Panels/AgentSessionManagedJSON.swift"),
            str(ROOT / "Sources/Panels/CodexManagedStreamDecoder.swift"),
            str(ROOT / "scripts/tests/fixtures/managed_codex_stream_main.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_decoder(self, actions):
        result = subprocess.run([str(self.executable)], input=json.dumps(actions),
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exact_request_notification_response_and_error_envelopes_stay_distinct(self):
        messages = [
            {"id": 7, "method": "item/tool/call",
             "params": {"threadId": "thread-A", "turnId": "turn-A", "callId": "call-A",
                        "namespace": None, "tool": "cmux_run_foreground", "arguments": {}}},
            {"method": "turn/completed", "params": {"threadId": "thread-A", "turn": {"id": "turn-A"}}},
            {"id": "7", "result": {"turn": {"id": "turn-A"}}},
            {"id": -7, "error": {"code": -32600, "message": "refused", "data": None}},
        ]
        rows = self.run_decoder([chunk(b"".join(map(wire, messages))), {"finish": True}])
        self.assertEqual([message["object"] for message in rows[0]["messages"]], messages)
        self.assertEqual([message["kind"] for message in rows[0]["messages"]],
                         ["request", "notification", "response", "error"])
        self.assertEqual([message["idKind"] for message in rows[0]["messages"]],
                         ["integer", "", "string", "integer"])
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)

    def test_raw_fields_and_multibyte_text_survive_every_pipe_boundary(self):
        message = {"method": "future/unsupported", "params": {"literal": "雪 🐈\n\\literal",
                                                            "opaque": [False, None, ""]}}
        data = wire(message)
        rows = self.run_decoder([*(chunk(bytes([byte])) for byte in data), {"finish": True}])
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)
        self.assertTrue(all(not row["messages"] for row in rows[:-2]), rows)
        self.assertEqual(rows[-2]["messages"][0]["object"], message)
        self.assertFalse(rows[-2]["pending"])
        self.assertTrue(all(row["pending"] for row in rows[:-2]))

    def test_string_and_integer_request_ids_never_alias_or_lose_64_bit_precision(self):
        identifiers = ["1", 1, -9223372036854775808, 9223372036854775807]
        rows = self.run_decoder([chunk(b"".join(wire({"id": value, "result": None})
                                              for value in identifiers)), {"finish": True}])
        self.assertEqual([message["object"]["id"] for message in rows[0]["messages"]], identifiers)
        self.assertEqual([message["idKind"] for message in rows[0]["messages"]],
                         ["string", "integer", "integer", "integer"])
        self.assertEqual(rows[0]["failure"], "")

    def test_incomplete_json_at_real_eof_cannot_be_forced_out_or_resumed(self):
        rows = self.run_decoder([chunk(b'{"id":"A","result":null}'), {"finish": True},
                                 chunk(b"\n"), {"finish": True}])
        self.assertEqual(rows[0]["messages"], [])
        self.assertTrue(rows[0]["pending"])
        self.assertEqual([row["failure"] for row in rows[1:]], ["incompleteLine"] * 3)
        self.assertTrue(all(not row["messages"] for row in rows))

    def test_invalid_utf8_latches_instead_of_decoding_replacement_text(self):
        for invalid in (b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"):
            with self.subTest(invalid=invalid):
                rows = self.run_decoder([
                    chunk(b'{"method":"future/event","params":"' + invalid + b'"}\n'),
                    chunk(wire({"id": "A", "result": None})), {"finish": True},
                ])
                self.assertEqual([row["failure"] for row in rows], ["invalidUTF8"] * 3)
                self.assertTrue(all(not row["messages"] for row in rows))

    def test_byte_limit_is_inclusive_and_overflow_never_recovers(self):
        prefix, suffix = b'{"method":"future/event","params":"', b'"}'
        exact = prefix + b"x" * (LIMIT - len(prefix) - len(suffix)) + suffix
        rows = self.run_decoder([chunk(exact), chunk(b"\n"), {"finish": True}])
        self.assertEqual(rows[0]["messages"], [])
        self.assertEqual(len(rows[1]["messages"][0]["object"]["params"]),
                         LIMIT - len(prefix) - len(suffix))
        self.assertTrue(all(row["failure"] == "" for row in rows), rows[-1])
        overflow = self.run_decoder([chunk(exact + b" "), chunk(b"\n"), {"finish": True}])
        self.assertEqual([row["failure"] for row in overflow], ["lineTooLarge"] * 3)
        self.assertTrue(all(not row["messages"] for row in overflow))

    def test_finish_is_idempotent_but_any_append_after_eof_is_closed(self):
        rows = self.run_decoder([{"finish": True}, {"finish": True}, chunk(b""),
                                 chunk(wire({"id": "A", "result": None})), {"finish": True}])
        self.assertEqual([row["failure"] for row in rows], ["", "", "closed", "closed", "closed"])
        self.assertTrue(all(not row["messages"] for row in rows))

    def test_malformed_or_ambiguous_envelopes_are_terminal_not_best_effort(self):
        invalid = [
            {}, {"id": "A"}, {"method": ""}, {"method": False},
            {"method": "turn/completed", "id": None},
            {"method": "turn/completed", "id": False},
            {"id": "A", "method": False, "result": {}},
            {"id": "A", "method": "item/tool/call", "result": {}},
            {"id": "A", "method": "item/tool/call", "error": {}},
            {"id": "A", "result": {}, "error": {"code": -1, "message": "conflict"}},
            {"id": "A", "result": {}, "params": {}},
            {"method": "turn/completed", "params": {}, "result": {}},
            {"method": "turn/completed", "trace": {"traceparent": "not-on-notifications"}},
            {"id": "A", "method": "item/tool/call", "trace": "not-an-object"},
            {"id": "A", "error": {}},
            {"id": "A", "error": {"code": True, "message": "not-an-integer"}},
            {"id": "A", "error": {"code": -1, "message": False}},
            {"id": "A", "error": {"code": -1, "message": "refused", "success": True}},
            {"jsonrpc": "2.0", "id": "A", "result": {}},
        ]
        for message in invalid:
            with self.subTest(message=message):
                rows = self.run_decoder([chunk(wire(message)), chunk(wire({"id": "B", "result": {}})),
                                         {"finish": True}])
                self.assertEqual([row["failure"] for row in rows], ["invalidEnvelope"] * 3, message)
                self.assertTrue(all(not row["messages"] for row in rows), rows)

    def test_invalid_request_id_types_do_not_become_notifications_or_integer_aliases(self):
        for identifier in (None, False, True, 1.25, 1.0, "", [], {}, 9223372036854775808,
                           -9223372036854775809, "x" * 4097):
            for fields in ({"result": {}}, {"method": "item/tool/call", "params": {}}):
                message = {"id": identifier, **fields}
                with self.subTest(message=message):
                    rows = self.run_decoder([chunk(wire(message)),
                                             chunk(wire({"id": "B", "result": {}})), {"finish": True}])
                    self.assertEqual([row["failure"] for row in rows], ["invalidEnvelope"] * 3)
                    self.assertTrue(all(not row["messages"] for row in rows), rows)

    def test_invalid_json_and_nonobjects_cannot_be_silently_skipped(self):
        for data, expected in (
            (b'{"id":\n', "invalidJSON"), (b"[]\n", "invalidEnvelope"),
            (b"null\n", "invalidJSON"), (b"\n", "invalidJSON"),
        ):
            with self.subTest(data=data):
                rows = self.run_decoder([chunk(data), chunk(wire({"id": "B", "result": {}})),
                                         {"finish": True}])
                self.assertEqual([row["failure"] for row in rows], [expected] * 3)
                self.assertTrue(all(not row["messages"] for row in rows), rows)

    def test_a_valid_message_with_a_partial_next_frame_is_never_a_drained_stream(self):
        message = {"id": "A", "result": {}}
        rows = self.run_decoder([chunk(wire(message) + b'{"method":"turn/started"'), {"finish": True}])
        self.assertEqual(rows[0]["messages"][0]["object"], message)
        self.assertTrue(rows[0]["pending"])
        self.assertEqual(rows[1]["failure"], "incompleteLine")

    def test_duplicate_json_members_at_any_depth_cannot_change_wire_identity(self):
        for data in (
            b'{"id":"foreign","id":"owned","result":{}}\n',
            b'{"id":"foreign","\\u0069d":"owned","result":{}}\n',
            b'{"id":"A","result":{"turn":{"id":"foreign","id":"owned"}}}\n',
            b'{"method":"event","params":[{"callId":"A","callId":"B"}]}\n',
            b'{"method":"event","params":{"a\\\\\\"b":1,"a\\\\\\"b":2}}\n',
        ):
            with self.subTest(data=data):
                rows = self.run_decoder([chunk(data), chunk(wire({"id": "B", "result": {}})),
                                         {"finish": True}])
                self.assertEqual([row["failure"] for row in rows], ["duplicateKey"] * 3)
                self.assertTrue(all(not row["messages"] for row in rows), rows)

    def test_keys_in_distinct_objects_and_json_looking_literal_strings_are_not_duplicates(self):
        message = {"method": "event", "params": {
            "literal": '{"id":"A","id":"B",["escaped"]}',
            "objects": [{"id": "A"}, {"id": "B"}],
            "a\"b": {"a\"b": 1},
        }}
        rows = self.run_decoder([chunk(wire(message)), {"finish": True}])
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)
        self.assertEqual(rows[0]["messages"][0]["object"], message)

    def test_wire_size_preserves_actual_utf8_whitespace_and_crlf_not_reserialized_size(self):
        data = '  { "id" : "A", "result" : "雪 🐈" } \r\n'.encode()
        rows = self.run_decoder([chunk(data), {"finish": True}])
        self.assertEqual(rows[0]["failure"], "")
        self.assertEqual(rows[0]["messages"][0]["wireBytes"], len(data))
        self.assertEqual(rows[0]["messages"][0]["object"], {"id": "A", "result": "雪 🐈"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
