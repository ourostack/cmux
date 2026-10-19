public import Foundation

/// Only the synchronous producer creates this proof; queued UI state cannot restore it.
public struct ShepherdHookProducerProof: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let launchReceiptID: UUID
    public let promptID: UUID
    public let workRevision: UUID
    public let scope: ShepherdHookReadinessScope
    public let nonce: UUID

    init(
        sessionID: String, launchReceiptID: UUID, promptID: UUID,
        workRevision: UUID, scope: ShepherdHookReadinessScope
    ) {
        version = 2
        self.sessionID = sessionID
        self.launchReceiptID = launchReceiptID
        self.promptID = promptID
        self.workRevision = workRevision
        self.scope = scope
        nonce = UUID()
    }
}
