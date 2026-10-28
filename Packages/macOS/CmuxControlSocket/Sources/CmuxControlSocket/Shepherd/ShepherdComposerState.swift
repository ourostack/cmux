/// Host-observed composer contents, never instructions from terminal output.
public enum ShepherdComposerState: Equatable, Sendable {
    /// The host cannot identify the active input area.
    case unknown
    /// The recognized input area is positively empty.
    case empty
    /// The recognized input area contains this exact literal draft.
    case draft(String)
    /// A menu or dialog is waiting for a selection rather than plain text.
    case dialog
}
