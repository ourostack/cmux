import CMUXAgentLaunch
import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct ShepherdRenderEvidenceTests {
    @Test func composerOnlyChangesLeaveOutsideEvidenceStable() throws {
        let before = ShepherdRenderEvidence(frame: try shepherdRenderFrame(), agent: "claude")
        let after = ShepherdRenderEvidence(frame: try shepherdRenderFrame(draft: "Continue the work."), agent: "claude")
        #expect(before.state == .empty)
        #expect(after.state == .draft("Continue the work."))
        #expect(before.outsideComposerFingerprint.count == 64)
        #expect(before.outsideComposerFingerprint == after.outsideComposerFingerprint)
    }

    @Test(arguments: ["output", "number", "footer", "rule", "column", "rows", "screen", "mode", "cursor", "color"])
    func everyMaterialOutsideChangeInvalidatesEvidence(change: String) throws {
        let original = try shepherdRenderFrame()
        var changed = original
        switch change {
        case "output": changed.rowSpans[0].text = "Different output"
        case "number": changed.rowSpans[0].text = "Completed 13 tests"
        case "footer": changed.rowSpans[4].text = "2 background tasks"
        case "rule": changed.rowSpans[1].text += "\u{2500}"
        case "column": changed.columns += 1
        case "rows": changed.rows += 1
        case "screen": changed.activeScreen = .alternate
        case "mode": changed.modes = [.init(code: 2004, on: true)]
        case "cursor": changed.cursor = .init(row: 0, column: 3)
        default: changed.terminalForeground = "#abcdef"
        }
        #expect(ShepherdRenderEvidence(frame: original, agent: "claude").outsideComposerFingerprint !=
                ShepherdRenderEvidence(frame: changed, agent: "claude").outsideComposerFingerprint)
    }

    @Test(arguments: ["foreground", "background", "bold", "faint", "italic", "underline",
                      "blink", "inverse", "invisible", "strikethrough", "overline", "source"])
    func allResolvedOutsideStyleAttributesAreBound(attribute: String) throws {
        let original = try shepherdRenderFrame()
        var changed = original
        switch attribute {
        case "foreground": changed.styles[0].foreground = "#123456"
        case "background": changed.styles[0].background = "#123456"
        case "bold": changed.styles[0].bold = true
        case "faint": changed.styles[0].faint = true
        case "italic": changed.styles[0].italic = true
        case "underline": changed.styles[0].underline = true
        case "blink": changed.styles[0].blink = true
        case "inverse": changed.styles[0].inverse = true
        case "invisible": changed.styles[0].invisible = true
        case "strikethrough": changed.styles[0].strikethrough = true
        case "overline": changed.styles[0].overline = true
        default: changed.styles[0].foregroundSource = .palette; changed.styles[0].foregroundPaletteIndex = 3
        }
        #expect(ShepherdRenderEvidence(frame: original, agent: "claude").outsideComposerFingerprint !=
                ShepherdRenderEvidence(frame: changed, agent: "claude").outsideComposerFingerprint)
    }

    @Test func equivalentStyleIDsAndCaptureCountersDoNotInventOutputChanges() throws {
        let original = try shepherdRenderFrame()
        var changed = original
        changed.styles[0].id = 9
        changed.rowSpans = changed.rowSpans.map { span in
            var span = span
            if span.styleID == 0 { span.styleID = 9 }
            return span
        }.reversed()
        changed.stateSeq = 99
        changed.renderRevision = 23
        changed.appliedInputSequence = 4
        #expect(ShepherdRenderEvidence(frame: original, agent: "claude").outsideComposerFingerprint ==
                ShepherdRenderEvidence(frame: changed, agent: "claude").outsideComposerFingerprint)
    }

    @Test(arguments: ["agent", "codex", "copilot", "frame", "viewport", "delta", "prefix", "boxed",
                      "dialog", "styles", "overlap", "row", "style", "format", "blank-multirow",
                      "whitespace-draft", "cursor-hidden", "cursor-missing", "cursor-moved"])
    func unavailableEvidenceIsLiterallyEmptyNeverComparableSentinel(failure: String) throws {
        var frame: MobileTerminalRenderGridFrame? = try shepherdRenderFrame()
        var agent: String? = "claude"
        switch failure {
        case "agent": agent = nil
        case "codex": agent = "codex"
        case "copilot": agent = "copilot"
        case "frame": frame = nil
        case "viewport": frame?.anchor = .viewport
        case "delta": frame?.full = false
        case "prefix": frame?.rowSpans[2].text = "ordinary shell prompt"
        case "boxed": frame?.rowSpans[2].text = "\u{2502} \u{276F}\u{00A0}hidden draft \u{2502}"
        case "dialog": frame?.rowSpans[4].text = "Enter to confirm"
        case "styles": frame?.styles.append(.default)
        case "overlap": frame?.rowSpans.append(.init(row: 2, column: 1, text: "hidden draft"))
        case "row": frame?.rowSpans[0].row = -1
        case "style": frame?.rowSpans[0].styleID = 999
        case "format": frame?.format = "unknown"
        case "whitespace-draft":
            frame?.rowSpans[2].text += "  "
            frame?.cursor?.column = 4
        case "cursor-hidden": frame?.cursor?.visible = false
        case "cursor-missing": frame?.cursor = nil
        case "cursor-moved": frame?.cursor?.column = 3
        default:
            frame?.rows = 7
            frame?.rowSpans[3].row = 4
            frame?.rowSpans[4].row = 5
        }
        let value = ShepherdRenderEvidence(frame: frame, agent: agent)
        #expect(value.state == .unknown)
        #expect(value.outsideComposerFingerprint == "")
    }
}

func shepherdRenderFrame(surfaceID: UUID = UUID(), draft: String = "") throws -> MobileTerminalRenderGridFrame {
    let rule = String(repeating: "\u{2500}", count: 40)
    return try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID.uuidString, stateSeq: 0, columns: 80, rows: 6,
        cursor: .init(row: 2, column: 2),
        styles: [.default, .init(id: 1, faint: true)],
        rowSpans: [
            .init(row: 0, column: 0, text: "Completed 12 tests"),
            .init(row: 1, column: 0, text: rule),
            .init(row: 2, column: 0, text: "\u{276F}\u{00A0}" + draft),
            .init(row: 3, column: 0, text: rule),
            .init(row: 4, column: 0, text: "auto mode on"),
        ], anchor: .screen
    )
}
