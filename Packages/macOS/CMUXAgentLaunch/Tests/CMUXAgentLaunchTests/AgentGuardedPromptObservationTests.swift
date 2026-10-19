import Testing
@testable import CMUXAgentLaunch

@Suite struct AgentGuardedPromptObservationTests {
    private let rule = String(repeating: "\u{2500}", count: 40)
    private func span(_ text: String, column: Int = 0, faint: Bool = false) -> AgentPromptScreenSpan {
        .init(column: column, text: text, faint: faint)
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
