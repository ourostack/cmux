public import Foundation

/// The native, main-actor observation and immediate-input seam for admission.
///
/// Implementations must read host-owned facts, never caller-supplied readiness.
/// Input must not create, queue, focus or clear a terminal. A snapshot is only
/// evidence; the implementation must also check identity at its write boundary.
@MainActor
public protocol ShepherdAdmissionHost: AnyObject {
    /// Reads current facts for the exact target without changing its focus.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace bound to the observation.
    ///   - surfaceID: The surface bound to the observation.
    /// - Returns: Current facts, or nil when the target cannot be observed.
    func snapshot(workspaceID: UUID, surfaceID: UUID) -> ShepherdAdmissionSnapshot?

    /// Admits literal text only to the still-matching live native target.
    ///
    /// - Parameters:
    ///   - request: The immutable continuation intent.
    ///   - snapshot: Fresh target evidence checked by the admission kernel.
    ///   - expiresAt: The original token's deadline in the injected uptime clock.
    /// - Returns: `.notAdmitted` only when zero input was admitted.
    func paste(
        request: ShepherdContinuationRequest,
        snapshot: ShepherdAdmissionSnapshot,
        expiresAt: TimeInterval
    ) -> ShepherdPasteWriteResult

    /// Admits Enter only for this request's still-live native reservation.
    ///
    /// - Parameters:
    ///   - requestID: The request that admitted the paste.
    ///   - snapshot: The freshly verified post-paste target and composer.
    /// - Returns: Whether the native runtime admitted the submit stroke.
    func submit(requestID: UUID, snapshot: ShepherdAdmissionSnapshot) -> Bool

    /// Releases only this request's reservation, including on cancellation.
    ///
    /// - Parameters:
    ///   - requestID: The reservation to release.
    ///   - snapshot: The original bound target, not permission to recreate it.
    func releaseReservation(requestID: UUID, snapshot: ShepherdAdmissionSnapshot)
}
