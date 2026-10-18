public import Foundation

/// A short-lived native observation lease, not a mandate or human permission.
public struct ShepherdObservationToken: Equatable, Sendable {
    /// The native owner's opaque, one-use observation identity.
    public let id: UUID
    /// The expiry in the host's injected uptime clock, not wall-clock time.
    public let expiresAt: TimeInterval
}
