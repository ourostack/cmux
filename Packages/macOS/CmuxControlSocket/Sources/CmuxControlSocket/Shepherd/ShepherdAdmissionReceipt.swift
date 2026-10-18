public import Foundation

/// A copy of one native owner's recorded outcome, not proof of task delivery.
public struct ShepherdAdmissionReceipt: Equatable, Sendable {
    /// The exact idempotent request identity.
    public let requestID: UUID
    /// The surface bound to the recorded operation.
    public let surfaceID: UUID
    /// The workspace bound to the recorded operation.
    public let workspaceID: UUID
    /// Its native foreground instance, or nil when unverified.
    public let processInstance: String?
    /// The recorded effect classification; mutating this copy changes no ledger.
    public var state: ShepherdAdmissionState
    /// The native owner's bounded outcome or refusal code.
    public var reason: String
    /// Whether the native owner admitted a paste, even when submit was withheld.
    public var pasteAdmitted: Bool
    /// Whether the native owner admitted the corresponding submit stroke.
    public var submitAdmitted: Bool
}
