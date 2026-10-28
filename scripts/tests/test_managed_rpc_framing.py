"""Exercise the native managed RPC codec without starting an app or provider."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd/ShepherdManagedRPCFramer.swift"
FIXTURE = Path(__file__).with_name("fixtures") / "managed_rpc_framer_main.swift"
MODULE_CACHE = None


class ManagedRPCFramingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-rpc-framing-"))
        cls.executable = cls.build / "framer"
        print(json.dumps({
            str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (SOURCE, FIXTURE, Path(__file__))
        }, sort_keys=True), file=sys.stderr)
        command = [
            "swiftc", "-swift-version", "6", "-gnone", "-parse-as-library",
            "-module-cache-path", str(MODULE_CACHE or cls.build / "cache"),
            str(SOURCE), str(FIXTURE), "-o", str(cls.executable),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        print(f"Retained native codec: {cls.build}", file=sys.stderr)

    def codec(self, chunks=(), *, finish=False, encode=None, followup=None):
        value = {
            "chunks": [base64.b64encode(chunk).decode() for chunk in chunks],
            "finish": finish,
        }
        if encode is not None:
            value["encode"] = base64.b64encode(encode).decode()
        if followup is not None:
            value["followup"] = base64.b64encode(followup).decode()
        result = subprocess.run(
            [str(self.executable)], input=json.dumps(value).encode(),
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    @staticmethod
    def bodies(result):
        return [base64.b64decode(frame) for frame in result["frames"]]

    def test_writer_counts_utf8_bytes_not_characters(self):
        body = b'"\xc3\xa9\xf0\x9f\x99\x82"'
        result = self.codec(encode=body)
        self.assertNotIn("encodeError", result)
        self.assertEqual(base64.b64decode(result["encoded"]), b"Content-Length: 8\r\n\r\n" + body)

    def test_every_split_and_single_byte_fragment_reassembles_exact_body(self):
        body = b'{"text":"caf\xc3\xa9\xf0\x9f\x99\x82"}'
        wire = b"Content-Length: 20\r\n\r\n" + body
        self.assertEqual(len(body), 20)
        for split in range(len(wire) + 1):
            with self.subTest(split=split):
                result = self.codec([wire[:split], wire[split:]], finish=True)
                self.assertIsNone(result["error"])
                self.assertEqual(self.bodies(result), [body])
        result = self.codec([bytes([byte]) for byte in wire], finish=True)
        self.assertEqual(self.bodies(result), [body])
        self.assertIsNone(result["error"])

    def test_coalesced_messages_and_framing_magic_inside_body_remain_distinct(self):
        body = b'"Content-Length: 2\\r\\n\\r\\n{}"'
        wire = b"Content-Length: 2\r\n\r\n{}"
        wire += f"Content-Length: {len(body)}\r\n\r\n".encode() + body
        result = self.codec([wire] * 3, finish=True)
        self.assertIsNone(result["error"])
        self.assertEqual(self.bodies(result), [b"{}", body] * 3)

    def test_header_names_are_case_insensitive_and_optional_utf8_type_is_supported(self):
        result = self.codec([
            b"content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}"
        ], finish=True)
        self.assertIsNone(result["error"])
        self.assertEqual(self.bodies(result), [b"{}"])

    def test_duplicate_length_is_rejected_even_when_case_differs(self):
        result = self.codec([b"Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}"])
        self.assertEqual(result["error"], "invalidHeader")

    def test_invalid_lengths_never_become_body_admission(self):
        for length in (b"0", b"-1", b"+2", b"2oops", b"2.0", b"", b"999999999999999999999999999"):
            with self.subTest(length=length):
                result = self.codec([b"Content-Length: " + length + b"\r\n\r\n{}"])
                self.assertEqual(result["error"], "invalidLength")
                self.assertEqual(result["frames"], [])

    def test_excessive_declared_body_is_rejected_without_waiting_for_body(self):
        result = self.codec([b"Content-Length: 1048577\r\n\r\n"])
        self.assertEqual(result["error"], "bodyTooLarge")

    def test_header_buffer_is_bounded_without_a_delimiter(self):
        result = self.codec([b"x" * 8193])
        self.assertEqual(result["error"], "headerTooLarge")

    def test_exact_header_limit_is_accepted_but_one_extra_byte_is_not(self):
        prefix = b"Content-Length: 2\r\nContent-Type: application/json"
        header = prefix + b" " * (8192 - len(prefix) - 4) + b"\r\n\r\n"
        self.assertEqual(len(header), 8192)
        result = self.codec([header + b"{}"], finish=True)
        self.assertIsNone(result["error"])
        self.assertEqual(self.bodies(result), [b"{}"])
        result = self.codec([prefix + b" " + header[len(prefix):] + b"{}"])
        self.assertEqual(result["error"], "headerTooLarge")

    def test_exact_body_limit_is_admitted_and_larger_write_is_refused(self):
        body = b"x" * 1048576
        result = self.codec([b"Content-Length: 1048576\r\n\r\n", body], finish=True)
        self.assertIsNone(result["error"])
        self.assertEqual(self.bodies(result), [body])
        result = self.codec(encode=body + b"x")
        self.assertEqual(result["encodeError"], "bodyTooLarge")

    def test_non_ascii_and_bare_linefeed_headers_are_rejected(self):
        for wire in (b"Content-Length: 2\n\n{}", b"Content-Length: 2\rX", b"\xff: 2\r\n\r\n{}"):
            with self.subTest(wire=wire):
                result = self.codec([wire])
                self.assertEqual(result["error"], "invalidHeader")

    def test_missing_length_and_unsupported_encoding_cannot_fall_back(self):
        result = self.codec([b"Content-Type: application/json\r\n\r\n{}"])
        self.assertEqual(result["error"], "invalidHeader")
        result = self.codec([b"Content-Length: 2\r\nContent-Type: application/json; charset=utf-16\r\n\r\n{}"])
        self.assertEqual(result["error"], "unsupportedEncoding")

    def test_complete_invalid_utf8_is_a_transport_failure(self):
        result = self.codec([b"Content-Length: 2\r\n\r\n\xc3("])
        self.assertEqual(result["error"], "invalidUTF8")
        result = self.codec(encode=b"\xff")
        self.assertEqual(result["encodeError"], "invalidUTF8")

    def test_each_nonempty_truncated_prefix_fails_at_real_eof(self):
        wire = b"Content-Length: 2\r\n\r\n{}"
        for cut in range(1, len(wire)):
            with self.subTest(cut=cut):
                result = self.codec([wire[:cut]], finish=True)
                self.assertEqual(result["error"], "incompleteFrame")

    def test_failure_is_sticky_and_later_valid_frame_does_not_rearm(self):
        result = self.codec([b"Content-Length: -1\r\n\r\n"], followup=b"Content-Length: 2\r\n\r\n{}")
        self.assertEqual(result["error"], "invalidLength")
        self.assertEqual(result["followupError"], "invalidLength")
        self.assertEqual(result["frames"], [])

    def test_clean_eof_closes_the_codec_without_fabricating_a_message(self):
        result = self.codec([], finish=True, followup=b"Content-Length: 2\r\n\r\n{}")
        self.assertIsNone(result["error"])
        self.assertEqual(result["frames"], [])
        self.assertEqual(result["followupError"], "closed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--fixture", type=Path, default=FIXTURE)
    parser.add_argument("--module-cache-path", type=Path)
    options, remaining = parser.parse_known_args()
    SOURCE, FIXTURE, MODULE_CACHE = options.source, options.fixture, options.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
