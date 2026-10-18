/// What the native input owner knows about a request's admitted effects.
public enum ShepherdAdmissionState: String, Equatable, Sendable {
    /// Zero input was admitted; this is never used for a partial paste.
    case notSent = "not_sent"
    /// Both bound native paste and submit were admitted, not certified consumed.
    case accepted
    /// Effects are partial or uncertain and must not be replayed automatically.
    case unknown
}
