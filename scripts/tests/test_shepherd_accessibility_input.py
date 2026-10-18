"""Execute accessibility insertion against a reservation-aware transport seam.

This verifies the actual AX dispatch methods, not native delivery or dictation.
"""

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


def swift_method(path, declaration):
    lines = path.read_text().splitlines(True)
    start = next(i for i, line in enumerate(lines) if line.startswith(declaration))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip() == "    }")
    return "".join(lines[start:end + 1])


class ShepherdAccessibilityInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        accessibility = ROOT / "Sources/GhosttyNSView+Accessibility.swift"
        text_rules = ROOT / "Sources/TerminalAccessibilityText.swift"
        methods = "".join(swift_method(accessibility, declaration) for declaration in (
            "    override func setAccessibilityValue(",
            "    override func setAccessibilitySelectedText(",
            "    private static func accessibilityCommittedString(",
            "    private func insertAccessibilityCommittedText(",
        ))
        rules = "".join(swift_method(text_rules, declaration) for declaration in (
            "    static func splitTrailingLineBreaks(",
            "    static func containsLineBreak(",
            "    static func pastePayload(",
        ))
        source = """
import Foundation

@MainActor
final class InputTransport {
    var reserved: Bool
    var exclusionDepth = 0
    var acceptsPaste = true
    var writes: [[String]] = []
    let hasLiveSurface = true

    init(reserved: Bool) { self.reserved = reserved }
    func beginShepherdInputExclusion() { exclusionDepth += 1 }
    func endShepherdInputExclusion() { exclusionDepth -= 1 }
    @discardableResult
    func didReceiveExplicitInput() -> Bool {
        reserved = false
        return false
    }
    func admitShepherd() -> Bool {
        guard exclusionDepth == 0, !reserved else { return false }
        reserved = true
        return true
    }
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard !reserved, acceptsPaste else { return false }
        beginShepherdInputExclusion()
        defer { endShepherdInputExclusion() }
        didReceiveExplicitInput()
        writes.append(["paste", text])
        return true
    }
}

@MainActor
class AccessibilityBase {
    func setAccessibilityValue(_ value: Any?) {}
    func setAccessibilitySelectedText(_ text: String?) {}
}

@MainActor
final class AccessibilityNotifications {
    func insertedText(settingValue value: String) -> String { value }
    func scheduleValueChanged(for element: AccessibilityProbe, onComplete: () -> Void) {}
    func invalidate() {}
}

@MainActor
enum TerminalAccessibilityText {
""" + rules + """
}

@MainActor
final class AccessibilityProbe: AccessibilityBase {
    let terminalSurface: InputTransport?
    let terminalAccessibilityText = AccessibilityNotifications()
    var reenterBeforeReturn = false
    var nestedAdmission: Bool?
    init(_ transport: InputTransport) { terminalSurface = transport }
    static func sanitizeExternalCommittedText(_ text: String) -> String { text }
    func unmarkText() {}
    func retainAccessibilityValueChangedFrameDemand() {}
    func releaseAccessibilityValueChangedFrameDemand() {}
    func withExternalCommittedText(_ body: () -> Void) {
        if reenterBeforeReturn, terminalSurface?.writes.isEmpty == false {
            nestedAdmission = terminalSurface?.admitShepherd()
        }
        body()
    }
    func insertText(_ text: String, replacementRange: NSRange) {
        guard let terminalSurface else { return }
        terminalSurface.beginShepherdInputExclusion()
        defer { terminalSurface.endShepherdInputExclusion() }
        terminalSurface.didReceiveExplicitInput()
        terminalSurface.writes.append(["typed", text])
    }
""" + methods + """
}

MainActor.assumeIsolated {
    var results: [String: Any] = [:]
    for entry in ["selected", "value"] {
        for scenario in ["takeover", "no-submit", "rejected", "reentry", "ordinary", "single-line", "empty"] {
            let transport = InputTransport(reserved: !["reentry", "ordinary"].contains(scenario))
            transport.acceptsPaste = scenario != "rejected"
            let probe = AccessibilityProbe(transport)
            probe.reenterBeforeReturn = scenario == "reentry"
            let content: String
            switch scenario {
            case "empty": content = ""
            case "single-line": content = "words\\n"
            case "no-submit": content = "first line\\nsecond line"
            default: content = "first line\\nsecond line\\n"
            }
            if entry == "selected" {
                probe.setAccessibilitySelectedText(content)
            } else {
                probe.setAccessibilityValue(content)
            }
            results[entry + ":" + scenario] = [
                "writes": transport.writes,
                "reserved": transport.reserved,
                "depth": transport.exclusionDepth,
                "nestedAdmission": probe.nestedAdmission.map { $0 as Any } ?? NSNull(),
            ]
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: results)
    print(String(decoding: data, as: UTF8.self))
}
"""
        result = subprocess.run(
            ["swift", "-swift-version", "5", "-"],
            input=source, text=True, capture_output=True, cwd=ROOT, timeout=60,
        )
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.actual = json.loads(result.stdout)

    def test_multiline_takeover_preserves_body_before_submit(self):
        for entry in ("selected", "value"):
            for scenario, want in (
                ("takeover", [["paste", "first line\nsecond line"], ["typed", "\n"]]),
                ("no-submit", [["paste", "first line\nsecond line"]]),
                ("ordinary", [["paste", "first line\nsecond line"], ["typed", "\n"]]),
            ):
                with self.subTest(entry=entry, scenario=scenario):
                    actual = self.actual[f"{entry}:{scenario}"]
                    self.assertEqual(actual["writes"], want)
                    self.assertFalse(actual["reserved"])
                    self.assertEqual(actual["depth"], 0)

    def test_rejected_body_never_sends_a_trailing_return(self):
        for entry in ("selected", "value"):
            with self.subTest(entry=entry):
                actual = self.actual[f"{entry}:rejected"]
                self.assertEqual(actual["writes"], [])
                self.assertFalse(actual["reserved"])
                self.assertEqual(actual["depth"], 0)

    def test_multipart_dispatch_excludes_reentrant_admission(self):
        for entry in ("selected", "value"):
            with self.subTest(entry=entry):
                actual = self.actual[f"{entry}:reentry"]
                self.assertIs(actual["nestedAdmission"], False)
                self.assertEqual(actual["writes"], [
                    ["paste", "first line\nsecond line"], ["typed", "\n"],
                ])
                self.assertFalse(actual["reserved"])
                self.assertEqual(actual["depth"], 0)

    def test_single_line_and_empty_input_preserve_existing_semantics(self):
        for entry in ("selected", "value"):
            with self.subTest(entry=entry):
                actual = self.actual[f"{entry}:single-line"]
                self.assertEqual(actual["writes"], [["typed", "words\n"]])
                self.assertFalse(actual["reserved"])
                self.assertEqual(actual["depth"], 0)
                actual = self.actual[f"{entry}:empty"]
                self.assertEqual(actual["writes"], [])
                self.assertTrue(actual["reserved"])
                self.assertEqual(actual["depth"], 0)


if __name__ == "__main__":
    unittest.main()
