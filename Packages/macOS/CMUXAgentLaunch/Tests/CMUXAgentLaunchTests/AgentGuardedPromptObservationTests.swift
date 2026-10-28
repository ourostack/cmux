import Testing
@testable import CMUXAgentLaunch

@Suite struct AgentGuardedPromptObservationTests {
    private let rule = String(repeating: "\u{2500}", count: 40)
    private func span(_ text: String, column: Int = 0, faint: Bool = false) -> AgentPromptScreenSpan {
        .init(column: column, text: text, faint: faint)
    }

    /// Fixtures follow the official Codex 0.154.0 composer layout, not a native capture.
    @Suite struct AgentGuardedCodexObservationTests {
        private let columns = 40
        private let terminalBackground = "#000000"

        private func span(
            _ text: String, column: Int = 0, faint: Bool = false, bold: Bool = false,
            background: String? = "#202020", width: Int? = nil
        ) -> AgentPromptScreenSpan {
            .init(column: column, text: text, faint: faint, bold: bold,
                  background: background, cellWidth: width ?? text.count)
        }

        private func screen(
            draft: String = "", faint: Bool = false, draftWidth: Int? = nil
        ) -> [[AgentPromptScreenSpan]] {
            let width = draftWidth ?? draft.count
            var input = [span("\u{203A}", bold: true), span(" ", column: 1)]
            if !draft.isEmpty {
                input.append(span(draft, column: 2, faint: faint, width: width))
            }
            input.append(span(String(repeating: " ", count: columns - 2 - width), column: 2 + width))
            return [
                [span("Completed 12 tests", background: terminalBackground)], [],
                [span(String(repeating: " ", count: columns))], input,
                [span(String(repeating: " ", count: columns))], [],
                [span("arbitrary footer text", background: terminalBackground)], [],
            ]
        }

        private func observe(
            _ rows: [[AgentPromptScreenSpan]], cursorRow: Int? = 3, agent: String = "codex"
        ) -> AgentGuardedPromptObservation? {
            AgentPromptInputState.guardedObservation(
                screenRows: rows, expectedAgent: agent, columns: columns,
                terminalBackground: terminalBackground, cursorRow: cursorRow
            )
        }

        @Test func opaqueSingleLineComposerHasAnExactEditableRange() throws {
            let empty = try #require(observe(screen()))
            let draft = try #require(observe(screen(draft: "Continue the work.")))
            #expect(empty.state == .empty)
            #expect(draft.state == .draft("Continue the work."))
            #expect(empty.editableRows == 3..<4)
            #expect(empty.editableRows == draft.editableRows)
            #expect(empty.emptyCursorColumn == 2)
        }

        @Test func onlyTheExactFaintPlaceholderCanBeEmpty() throws {
            let placeholder = "Ask Codex to do anything"
            #expect(try #require(observe(screen(draft: placeholder, faint: true))).state == .empty)
            #expect(try #require(observe(screen(draft: placeholder))).state == .draft(placeholder))
            #expect(observe(screen(draft: "invisible human draft", faint: true)) == nil)
            var mixed = screen(draft: placeholder, faint: true)
            mixed[3].removeLast()
            mixed[3].append(span(String(repeating: " ", count: columns - 4 - placeholder.count),
                                 column: 2 + placeholder.count))
            mixed[3].append(span("x ", column: columns - 2))
            #expect(observe(mixed) == nil)
        }

        @Test func nativeCursorSelectsTheCurrentComposerNotAHistoryBubble() throws {
            let old = Array(screen(draft: "prior request")[2...4])
            let rows = old + [[]] + screen()
            let value = try #require(observe(rows, cursorRow: 7))
            #expect(value.state == .empty)
            #expect(value.editableRows == 7..<8)
            #expect(observe(rows, cursorRow: 5) == nil)
            #expect(observe(rows, cursorRow: nil) == nil)
        }

        @Test func explicitGridWidthsPreserveWideDraftTextWithoutSynthesizingGaps() throws {
            let value = try #require(observe(screen(draft: "\u{1F642}", draftWidth: 2)))
            #expect(value.state == .draft("\u{1F642}"))
            var missing = screen(draft: "\u{1F642}", draftWidth: 2)
            missing[3][2].cellWidth = nil
            #expect(observe(missing) == nil)
        }

        @Test func blankRowsCannotHideAnotherDraftOrAttachment() {
            let blank = [span(String(repeating: " ", count: columns))]
            for extra in [blank, screen(draft: "hidden human draft")[3]] {
                var rows = screen()
                rows.insert(extra, at: 4)
                #expect(observe(rows) == nil)
            }
            var attachment = screen()
            attachment[2] = [span("[Image #1]" + String(repeating: " ", count: columns - 10))]
            #expect(observe(attachment) == nil)
        }

        @Test(arguments: ["bold", "disabled", "glyph", "separator", "background", "default-background",
                          "missing-background", "coverage", "overlap", "gap", "width", "wide-space", "top", "bottom",
                          "cursor", "agent", "dialog"])
        func missingOrAmbiguousEvidenceNeverGetsAnExclusion(failure: String) {
            var rows = screen()
            var cursor: Int? = 3
            var agent = "codex"
            switch failure {
            case "bold": rows[3][0].bold = false
            case "disabled": rows[3][0].faint = true
            case "glyph": rows[3][0].text = ">"
            case "separator": rows[3][1].text = "_"
            case "background": rows[3][1].background = "#303030"
            case "default-background":
                rows = rows.map { $0.map { var span = $0; span.background = terminalBackground; return span } }
            case "missing-background": rows[3][0].background = nil
            case "coverage": rows[2][0].text.removeLast(); rows[2][0].cellWidth = columns - 1
            case "overlap": rows[3][1].column = 0
            case "gap": rows[3][1].column = 2
            case "width": rows[3][0].cellWidth = 0
            case "wide-space":
                rows[3][1].cellWidth = 2
                rows[3][2] = span(String(repeating: " ", count: columns - 3), column: 3)
            case "top": rows[2][0].text = "x" + String(repeating: " ", count: columns - 1)
            case "bottom": rows[4][0].text = "x" + String(repeating: " ", count: columns - 1)
            case "cursor": cursor = nil
            case "agent": agent = "copilot"
            default: rows[6] = [span("Press enter to confirm or esc to go back", background: terminalBackground)]
            }
            #expect(observe(rows, cursorRow: cursor, agent: agent) == nil)
        }
    }
    private func screen(_ input: [[AgentPromptScreenSpan]]) -> [[AgentPromptScreenSpan]] {
        [[span("Completed 12 tests")], [span(rule)]] + input +
            [[span(rule)], [span("  auto mode on")]]
    }

    @Test func framedClaudeUsesOneRangeForComposerAndExclusion() throws {
        let value = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}")]]), expectedAgent: "claude"
        ))
        #expect(value.state == .empty)
        #expect(value.editableRows == 2..<3)
    }

    @Test func placeholderIsEmptyButTypedTextIsNot() throws {
        let empty = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}"), span("Try a prompt", column: 2, faint: true)]]),
            expectedAgent: "claude"
        ))
        let draft = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}Continue the work.")]]), expectedAgent: "claude"
        ))
        #expect(empty.state == .empty)
        #expect(draft.state == .draft("Continue the work."))
        #expect(empty.editableRows == draft.editableRows)
    }

    @Test func blankRowsCannotHideLaterHumanDraft() throws {
        let rows = screen([[span("\u{276F}\u{00A0}")], [], [span("  human draft after a blank")]])
        let value = try #require(AgentPromptInputState.guardedObservation(screenRows: rows, expectedAgent: "claude"))
        #expect(value.state == .draft("human draft after a blank"))
        #expect(value.editableRows == 2..<5)
        #expect(AgentPromptInputState(screenRows: rows) == .empty)
    }

    @Test func multipleRowsAreNotGuessedToBeASingleLinePaste() throws {
        let value = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}first line")], [span("  second line")]]),
            expectedAgent: "claude"
        ))
        #expect(value.state == .draft("first line\n  second line"))
    }

    @Test func coordinateGapsDoNotMakeTypedTextDisappear() throws {
        let value = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}first"), span("second", column: 10)]]), expectedAgent: "claude"
        ))
        #expect(value.state == .draft("first   second"))
    }

    @Test func aLiteralBoxBarIsHumanDraftNotChrome() throws {
        let value = try #require(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}\u{2502}")]]), expectedAgent: "claude"
        ))
        #expect(value.state == .draft("\u{2502}"))
    }

    @Test func boxedInputIsExplicitlyUnsupportedBeforeTextExtraction() {
        let rows = [
            [span("\u{256D}" + rule + "\u{256E}")],
            [span("\u{2502} \u{276F}\u{00A0}hidden human draft \u{2502}")],
            [span("\u{2570}" + rule + "\u{256F}")],
        ]
        #expect(AgentPromptInputState.guardedObservation(screenRows: rows, expectedAgent: "claude") == nil)
    }

    @Test func missingOrMisplacedFramingIsUnknown() {
        let rows = screen([[span("\u{276F}\u{00A0}")]])
        for malformed in [Array(rows.dropFirst(2)), Array(rows.dropLast(2)),
                          [[span(rule)], [], [span("\u{276F}\u{00A0}")], [span(rule)]],
                          [[span("\u{2502}")], [span("\u{276F}\u{00A0}")], [span(rule)]]] {
            #expect(AgentPromptInputState.guardedObservation(screenRows: malformed, expectedAgent: "claude") == nil)
        }
    }

    @Test(arguments: ["codex", "copilot", "unknown", ""])
    func aMatchingNativeAgentIsRequired(agent: String) {
        #expect(AgentPromptInputState.guardedObservation(
            screenRows: screen([[span("\u{276F}\u{00A0}")]]), expectedAgent: agent
        ) == nil)
    }

    @Test func codexBlankThenHiddenDraftThenFooterStaysUnsupported() {
        let rows = [
            [span("\u{203A} ")], [], [span("  hidden human draft")], [],
            [span("  gpt-6-astra high \u{00B7} /tmp/drafttest")],
        ]
        #expect(AgentPromptInputState.guardedObservation(screenRows: rows, expectedAgent: "codex") == nil)
    }

    @Test func dialogsAndMultipleInputMarkersNeverGetEditableExclusions() {
        let dialog = screen([[span("\u{276F}\u{00A0}1. Allow once")]]) + [[span("Enter to confirm")]]
        let ambiguous = screen([[span("\u{276F}\u{00A0}")], [span("\u{276F}\u{00A0}another input")]])
        #expect(AgentPromptInputState.guardedObservation(screenRows: dialog, expectedAgent: "claude") == nil)
        #expect(AgentPromptInputState.guardedObservation(screenRows: ambiguous, expectedAgent: "claude") == nil)
    }
}
