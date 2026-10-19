import CMUXAgentLaunch
import CMUXMobileCore
import CmuxTerminal
import CryptoKit
import Foundation

struct ShepherdRenderEvidence {
    private(set) var state: AgentPromptInputState = .unknown
    private(set) var outsideComposerFingerprint = ""

    init(frame: MobileTerminalRenderGridFrame?, agent: String?) {
        guard let frame, let agent, frame.anchor == .screen, frame.full,
              frame.format == MobileTerminalRenderGridFrame.currentFormat,
              Set(frame.styles.map(\.id)).count == frame.styles.count,
              let validated = try? MobileTerminalRenderGridFrame(
                  surfaceID: frame.surfaceID, stateSeq: 0, columns: frame.columns, rows: frame.rows,
                  cursor: frame.cursor, styles: frame.styles, rowSpans: frame.rowSpans
              ) else { return }
        let styles = Dictionary(uniqueKeysWithValues: validated.styles.map { ($0.id, $0) })
        var rows = Array(repeating: [AgentPromptScreenSpan](), count: frame.rows)
        let spans = validated.rowSpans.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        for span in spans {
            guard let style = styles[span.styleID] else { return }
            let background = style.inverse || style.invisible ? nil : style.background ?? frame.terminalBackground
            rows[span.row].append(.init(
                column: span.column, text: span.text, faint: style.faint, bold: style.bold,
                background: background, cellWidth: span.cellWidth
            ))
        }
        let visibleCursor = frame.cursor.flatMap { $0.visible ? $0 : nil }
        let codexCoordinatesKnown = visibleCursor.map { $0.column >= 2 && $0.column < frame.columns - 1 } == true
            && !frame.modes.contains { !$0.ansi && $0.code == 5 && $0.on }
        guard let observation = AgentPromptInputState.guardedObservation(
            screenRows: rows, expectedAgent: agent, columns: frame.columns,
            terminalBackground: frame.terminalBackground,
            cursorRow: agent == "codex" && !codexCoordinatesKnown ? nil : visibleCursor?.row
        ) else { return }
        if observation.state == .empty {
            guard let cursor = frame.cursor, cursor.visible,
                  cursor.row == observation.editableRows.lowerBound,
                  cursor.column == observation.emptyCursorColumn else { return }
        }
        var outside: [OutsideSpan] = []
        for span in spans where !observation.editableRows.contains(span.row) {
            guard var style = styles[span.styleID] else { return }
            style.id = 0
            outside.append(OutsideSpan(row: span.row, column: span.column, width: span.cellWidth,
                                       text: span.text, style: style))
        }
        let cursor = frame.cursor.flatMap { observation.editableRows.contains($0.row) ? nil : $0 }
        let evidence = OutsideFrame(
            columns: frame.columns, rows: frame.rows, screen: frame.activeScreen,
            spans: outside, cursor: cursor, modes: frame.modes,
            foreground: frame.terminalForeground, background: frame.terminalBackground,
            cursorColor: frame.terminalCursorColor
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(evidence) else { return }
        state = observation.state
        outsideComposerFingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func capture(surface: TerminalSurface, surfaceID: UUID, agent: String?) -> Self {
        guard let frame = surface.mobileRenderGridFrame(
            stateSeq: 0, includeTheme: false, anchor: .screen
        )?.frame, UUID(uuidString: frame.surfaceID) == surfaceID else {
            return Self(frame: nil, agent: nil)
        }
        return Self(frame: frame, agent: agent)
    }

    private struct OutsideSpan: Encodable {
        let row: Int
        let column: Int
        let width: Int?
        let text: String
        let style: MobileTerminalRenderGridFrame.Style
    }

    private struct OutsideFrame: Encodable {
        let columns: Int
        let rows: Int
        let screen: MobileTerminalRenderGridFrame.Screen
        let spans: [OutsideSpan]
        let cursor: MobileTerminalRenderGridFrame.Cursor?
        let modes: [MobileTerminalRenderGridFrame.ModeSetting]
        let foreground: String?
        let background: String?
        let cursorColor: String?
    }
}
