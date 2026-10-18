public import Foundation

/// An idempotent plain-text continuation intent, not permission to send input.
public struct ShepherdContinuationRequest: Equatable, Sendable {
    /// The caller's stable identity for this exact request.
    public let requestID: UUID
    /// A one-use observation token issued by the native admission owner.
    public let tokenID: UUID
    /// The exact single-line text to verify after paste.
    public let text: String

    /// Creates a continuation intent without admitting or normalizing input.
    ///
    /// - Parameters:
    ///   - requestID: The stable idempotency key.
    ///   - tokenID: The native observation token.
    ///   - text: Exact text; validation must precede any input.
    public init(requestID: UUID, tokenID: UUID, text: String) {
        self.requestID = requestID
        self.tokenID = tokenID
        self.text = text
    }

    var hasValidText: Bool { true }
}
