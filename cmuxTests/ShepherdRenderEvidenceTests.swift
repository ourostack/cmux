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

    @Test func codexComposerChangesPreserveAllOutsideEvidence() throws {
        let before = ShepherdRenderEvidence(frame: try shepherdCodexRenderFrame(), agent: "codex")
        let after = ShepherdRenderEvidence(
            frame: try shepherdCodexRenderFrame(draft: "Continue the work."), agent: "codex"
        )
        #expect(before.state == .empty)
        #expect(after.state == .draft("Continue the work."))
        #expect(before.outsideComposerFingerprint.count == 64)
        #expect(before.outsideComposerFingerprint == after.outsideComposerFingerprint)
    }

    @Test func codexCursorBindingIgnoresHistoricalComposerMarkers() throws {
        let value = ShepherdRenderEvidence(frame: try shepherdCodexRenderFrame(history: true), agent: "codex")
        #expect(value.state == .empty)
        #expect(value.outsideComposerFingerprint.count == 64)
    }

    @Test func codexWideDraftUsesActualExportedCellWidths() throws {
        let value = ShepherdRenderEvidence(
            frame: try shepherdCodexRenderFrame(draft: "\u{1F642}", draftWidth: 2), agent: "codex"
        )
        #expect(value.state == .draft("\u{1F642}"))
        #expect(value.outsideComposerFingerprint.count == 64)
    }

    @Test(arguments: ["output", "footer", "padding-style", "color", "columns", "mode"])
    func codexOutsideChangesNeverBorrowTheComposerExclusion(change: String) throws {
        let original = try shepherdCodexRenderFrame()
        var changed = original
        switch change {
        case "output": changed.rowSpans[0].text = "Different output"
        case "footer": changed.rowSpans[changed.rowSpans.count - 1].text = "2 background tasks"
        case "padding-style":
            changed.styles.append(.init(id: 4, background: "#202020", italic: true))
            changed.rowSpans[1].styleID = 4
        case "color": changed.terminalForeground = "#abcdef"
        case "columns": changed.columns += 1
        default: changed.modes = [.init(code: 2004, on: true)]
        }
        #expect(ShepherdRenderEvidence(frame: original, agent: "codex").outsideComposerFingerprint !=
                ShepherdRenderEvidence(frame: changed, agent: "codex").outsideComposerFingerprint)
    }

    @Test(arguments: ["inverse", "invisible", "reverse", "cursor-hidden", "cursor-missing",
                      "cursor-outside", "cursor-moved", "draft-cursor-prefix", "default-background",
                      "no-default-background", "background-gap", "bold", "width"])
    func codexUnsupportedNativeFactsStayUnknown(failure: String) throws {
        var frame = try shepherdCodexRenderFrame(draft: failure == "draft-cursor-prefix" ? "draft" : "")
        switch failure {
        case "inverse": frame.styles[1].inverse = true
        case "invisible": frame.styles[1].invisible = true
        case "reverse": frame.modes = [.init(code: 5, on: true)]
        case "cursor-hidden": frame.cursor?.visible = false
        case "cursor-missing": frame.cursor = nil
        case "cursor-outside": frame.cursor?.row = 0
        case "cursor-moved": frame.cursor?.column = 3
        case "draft-cursor-prefix": frame.cursor?.column = 1
        case "default-background":
            for index in 1..<frame.styles.count { frame.styles[index].background = "#000000" }
        case "no-default-background": frame.terminalBackground = nil
        case "background-gap":
            frame.rowSpans[1].text.removeLast()
            frame.rowSpans[1].cellWidth = frame.columns - 1
        case "bold": frame.styles[3].bold = false
        default: frame.rowSpans[2].cellWidth = 0
        }
        let value = ShepherdRenderEvidence(frame: frame, agent: "codex")
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

/// Source-derived Codex 0.154.0 geometry/styles; not installed-editor qualification.
func shepherdCodexRenderFrame(
    draft: String = "", draftWidth: Int? = nil, history: Bool = false
) throws -> MobileTerminalRenderGridFrame {
    let columns = 40
    let width = draftWidth ?? draft.count
    let shift = history ? 4 : 0
    var spans: [MobileTerminalRenderGridFrame.RowSpan] = []
    if history {
        spans += [
            .init(row: 0, column: 0, styleID: 1, text: String(repeating: " ", count: columns)),
            .init(row: 1, column: 0, styleID: 3, text: "\u{203A}", cellWidth: 1),
            .init(row: 1, column: 1, styleID: 1, text: " prior request" + String(repeating: " ", count: columns - 15)),
            .init(row: 2, column: 0, styleID: 1, text: String(repeating: " ", count: columns)),
        ]
    }
    spans += [
        .init(row: shift, column: 0, text: "Completed 12 tests"),
        .init(row: 2 + shift, column: 0, styleID: 1, text: String(repeating: " ", count: columns)),
        .init(row: 3 + shift, column: 0, styleID: 3, text: "\u{203A}", cellWidth: 1),
        .init(row: 3 + shift, column: 1, styleID: 1, text: " " + draft
              + String(repeating: " ", count: columns - 2 - width), cellWidth: columns - 1),
        .init(row: 4 + shift, column: 0, styleID: 1, text: String(repeating: " ", count: columns)),
        .init(row: 6 + shift, column: 0, text: "arbitrary footer text"),
    ]
    return try MobileTerminalRenderGridFrame(
        surfaceID: UUID().uuidString, stateSeq: 0, columns: columns, rows: 8 + shift,
        cursor: .init(row: 3 + shift, column: 2 + width),
        styles: [.default, .init(id: 1, background: "#202020"),
                 .init(id: 2, background: "#202020", faint: true),
                 .init(id: 3, background: "#202020", bold: true)],
        rowSpans: spans, terminalForeground: "#ffffff", terminalBackground: "#000000", anchor: .screen
    )
}
