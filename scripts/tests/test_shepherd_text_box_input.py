"""Execute TextBox forwarding against a reservation-aware transport seam.

This checks UI dispatch order, not native delivery or app-host qualification.
"""

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ShepherdTextBoxInputTests(unittest.TestCase):
    def test_physical_forwarding_cancels_before_the_shared_writer(self):
        lines = (ROOT / "Sources/TextBoxInput.swift").read_text().splitlines(True)
        methods = []
        for name in ("forwardText", "forwardKey", "forwardControl"):
            start = next(
                i for i, line in enumerate(lines)
                if line.startswith(f"    private func {name}(")
            )
            end = next(
                i for i in range(start + 1, len(lines))
                if lines[i].rstrip() == "    }"
            )
            methods.append("".join(lines[start:end + 1]))

        source = """
import Foundation

@MainActor
final class ForwardingTransport {
    var reserved = true
    var writes: [String] = []
    var cancellations = 0

    @discardableResult
    func didReceiveExplicitInput() -> Bool {
        reserved = false
        cancellations += 1
        return false
    }

    @discardableResult
    func sendNamedKey(_ key: String) -> Bool {
        guard !reserved else { return false }
        writes.append(key)
        return true
    }

    func sendInput(_ text: String) {
        guard !reserved else { return }
        writes.append(text)
    }
}

enum TextBoxTerminalKey: String {
    case tab
}

@MainActor
struct ForwardingProbe {
    let surface: ForwardingTransport
    private func focusTerminal() {}
""" + "".join(methods) + """
    func exercise(_ kind: String) {
        switch kind {
        case "control": forwardControl("c")
        case "key": forwardKey(.tab)
        default: forwardText("?", focusTerminalAfterSend: false)
        }
    }
}

MainActor.assumeIsolated {
    var results: [String: Any] = [:]
    for kind in ["control", "key", "text"] {
        let transport = ForwardingTransport()
        ForwardingProbe(surface: transport).exercise(kind)
        results[kind] = [
            "writes": transport.writes,
            "cancellations": transport.cancellations,
            "reserved": transport.reserved,
        ] as [String: Any]
    }
    let data = try! JSONSerialization.data(withJSONObject: results)
    print(String(decoding: data, as: UTF8.self))
}
"""
        result = subprocess.run(
            ["swift", "-swift-version", "5", "-"],
            input=source, text=True, capture_output=True, cwd=ROOT, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(result.stdout)
        for kind, expected in (("control", "ctrl-c"), ("key", "tab"), ("text", "?")):
            with self.subTest(kind=kind):
                self.assertEqual(actual[kind], {
                    "writes": [expected], "cancellations": 1, "reserved": False,
                })


if __name__ == "__main__":
    unittest.main()
