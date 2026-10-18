/// The immediate native writer's result, never an external editor completion.
public enum ShepherdPasteWriteResult: Equatable, Sendable {
    /// The native writer proves that zero input was admitted or queued.
    case notAdmitted
    /// Paste was admitted and advanced the native input revision to this value.
    case admitted(inputRevision: UInt64)
}
