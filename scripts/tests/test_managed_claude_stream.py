"""Actual raw managed decoder through OS pipes; no CLI, provider, app, or qualification."""

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


class ManagedClaudeStreamTests(unittest.TestCase):
    maxDiff = 1000

    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-claude-stream-source-"))
        print(f"Retained exact-source Claude decoder build: {cls.build}", file=sys.stderr)
        cls.executable = cls.build / "decoder"
        result = subprocess.run([
            "swiftc", "-swift-version", "6", "-gnone", "-parse-as-library",
            "-module-cache-path", str(MODULE_CACHE or cls.build / "cache"),
            str(ROOT / "Sources/Panels/AgentSessionManagedJSON.swift"),
            str(ROOT / "Sources/Panels/ClaudeManagedStreamDecoder.swift"),
            str(ROOT / "scripts/tests/fixtures/managed_claude_stream_main.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_decoder(self, actions):
        result = subprocess.run([str(self.executable)], input=json.dumps(actions),
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_raw_provider_fields_survive_every_byte_boundary_without_convenience_projection(self):
        message = {
            "type": "user", "isReplay": True, "uuid": "owned-input-A", "session_id": "session-A",
            "parent_tool_use_id": None, "message": {"role": "user", "content": "雪 🐈\n\\literal"},
            "future_unknown_field": {"exact": [False, None, ""]},
        }
        data = wire(message)
        rows = self.run_decoder([*(chunk(bytes([byte])) for byte in data), {"finish": True}])
        self.assertTrue(all(row["failure"] == "" for row in rows), rows)
        self.assertTrue(all(not row["messages"] for row in rows[:-2]), rows)
        self.assertEqual(rows[-2]["messages"], [message])
        self.assertEqual(rows[-1]["messages"], [])

    def test_multiple_messages_stay_distinct_and_unknown_types_reach_the_semantic_owner(self):
        messages = [
            {"type": "result", "user_message_uuids": ["A", "B"], "is_error": False},
            {"type": "control_request", "request_id": "request-1",
             "request": {"subtype": "hook_callback", "callback_id": "static-route",
                         "input": {"hook_event_name": "Stop", "prompt_id": "provider-P",
                                   "background_tasks": [], "session_crons": []}}},
            {"type": "future-unsupported", "opaque": 7},
        ]
        rows = self.run_decoder([chunk(b"".join(map(wire, messages))), {"finish": True}])
        self.assertEqual(rows[0]["messages"], messages)
        self.assertEqual(rows[0]["failure"], "")
        self.assertEqual(rows[1]["failure"], "")

    def test_incomplete_valid_json_at_real_eof_is_not_a_message(self):
        rows = self.run_decoder([chunk(b'{"type":"result"}'), {"finish": True},
                                 chunk(b"\n"), {"finish": True}])
        self.assertEqual(rows[0]["messages"], [])
        self.assertEqual([row["failure"] for row in rows[1:]], ["incompleteLine"] * 3)
        self.assertTrue(all(not row["messages"] for row in rows))

    def test_invalid_utf8_never_becomes_replacement_text_or_recovers_on_the_next_line(self):
        for invalid in (b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"):
            with self.subTest(invalid=invalid):
                rows = self.run_decoder([
                    chunk(b'{"type":"assistant","text":"' + invalid + b'"}\n'),
                    chunk(wire({"type": "result"})), {"finish": True},
                ])
                self.assertEqual([row["failure"] for row in rows], ["invalidUTF8"] * 3)
                self.assertTrue(all(not row["messages"] for row in rows))

    def test_malformed_or_nonobject_or_untyped_lines_latch_the_failure(self):
        for data, expected in (
            (b'{"type":\n', "invalidJSON"), (b"[]\n", "invalidEnvelope"),
            (b'{"type":false}\n', "invalidEnvelope"), (b"{}\n", "invalidEnvelope"),
            (b'{"type":""}\n', "invalidEnvelope"), (b"\n", "invalidJSON"),
        ):
            with self.subTest(data=data):
                rows = self.run_decoder([chunk(data), chunk(wire({"type": "result"})), {"finish": True}])
                self.assertEqual([row["failure"] for row in rows], [expected] * 3)
                self.assertTrue(all(not row["messages"] for row in rows))

    def test_a_line_at_the_byte_limit_is_accepted_but_a_larger_line_is_never_forced_out(self):
        prefix, suffix = b'{"type":"assistant","text":"', b'"}'
        exact = prefix + b"x" * (LIMIT - len(prefix) - len(suffix)) + suffix
        rows = self.run_decoder([chunk(exact), chunk(b"\n"), {"finish": True}])
        self.assertEqual(rows[0]["messages"], [])
        self.assertEqual(len(rows[1]["messages"][0]["text"]), LIMIT - len(prefix) - len(suffix))
        self.assertTrue(all(row["failure"] == "" for row in rows))
        overflow = self.run_decoder([chunk(exact + b" "), chunk(b"\n"), {"finish": True}])
        self.assertEqual([row["failure"] for row in overflow], ["lineTooLarge"] * 3)
        self.assertTrue(all(not row["messages"] for row in overflow))

    def test_finishing_an_empty_or_drained_stream_is_idempotent_and_append_after_eof_is_closed(self):
        rows = self.run_decoder([{"finish": True}, {"finish": True}, chunk(wire({"type": "result"})),
                                 {"finish": True}])
        self.assertEqual([row["failure"] for row in rows], ["", "", "closed", "closed"])
        self.assertTrue(all(not row["messages"] for row in rows))

    def test_duplicate_identity_members_at_any_depth_are_not_overwritten_by_foundation(self):
        for data in (
            b'{"type":"user","uuid":"foreign","uuid":"owned"}\n',
            b'{"type":"user","uuid":"foreign","\\u0075uid":"owned"}\n',
            b'{"type":"control_request","request":{"input":{"prompt_id":"A","prompt_id":"B"}}}\n',
            b'{"type":"result","data":[{"id":"A","id":"B"}]}\n',
            b'{"type":"assistant","params":{"a\\\\\\"b":1,"a\\\\\\"b":2}}\n',
        ):
            with self.subTest(data=data):
                rows = self.run_decoder([chunk(data), chunk(wire({"type": "result"})), {"finish": True}])
                self.assertEqual([row["failure"] for row in rows], ["duplicateKey"] * 3)
                self.assertTrue(all(not row["messages"] for row in rows), rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    MODULE_CACHE = options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
