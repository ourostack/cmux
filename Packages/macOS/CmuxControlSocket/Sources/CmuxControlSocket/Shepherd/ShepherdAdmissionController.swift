public import Foundation

/// Sequences one guarded paste and delayed submit without blocking native input.
///
/// The injected wait is a real minimum editor-processing delay, not polling.
/// Host facts are reread after it. This owns no duplicate receipt cache and
/// cannot make an unqualified host implementation safe by itself.
@MainActor
public final class ShepherdAdmissionController {
    /// Explicit failures before an input outcome can be returned.
    public enum Error: Swift.Error, Equatable, Sendable {
        /// The continuation text is not bounded, canonical single-line input.
        case invalidRequest
        /// No active observation binds the supplied token.
        case unknownToken
        /// The exact native target cannot be observed.
        case targetUnavailable
        /// An admitted request unexpectedly has no retained outcome.
        case receiptUnavailable
    }

    private let admission = ShepherdAdmission()
    private let host: any ShepherdAdmissionHost
    private let now: @MainActor () -> TimeInterval
    private let wait: @MainActor (TimeInterval) async throws -> Void

    /// Creates one native admission owner with explicit transport and clocks.
    ///
    /// - Parameters:
    ///   - host: The real native observation and immediate-input implementation.
    ///   - now: The uptime clock also used by the host's reservation deadlines.
    ///   - wait: A cancellable wait for at least the requested seconds.
    public init(
        host: any ShepherdAdmissionHost,
        now: @escaping @MainActor () -> TimeInterval,
        wait: @escaping @MainActor (TimeInterval) async throws -> Void
    ) {
        self.host = host
        self.now = now
        self.wait = wait
    }

    /// Inspects an exact target without inferring focus, idle or background state.
    ///
    /// - Parameters:
    ///   - workspaceID: The exact local workspace.
    ///   - surfaceID: The exact local surface.
    /// - Returns: Current facts and a token only when the kernel finds them ready.
    /// - Throws: ``Error/targetUnavailable`` for missing or mismatched targets.
    public func inspect(workspaceID: UUID, surfaceID: UUID) throws -> ShepherdAdmissionInspection {
        guard let snapshot = host.snapshot(workspaceID: workspaceID, surfaceID: surfaceID),
              snapshot.workspaceID == workspaceID, snapshot.surfaceID == surfaceID else {
            throw Error.targetUnavailable
        }
        return ShepherdAdmissionInspection(snapshot: snapshot, token: admission.inspect(snapshot: snapshot, now: now()))
    }

    /// Attempts this exact request once and retains any uncertain paste outcome.
    ///
    /// Existing requests return their recorded receipt without another write or
    /// delay. Cancellation after paste withholds submit and releases the native
    /// reservation; it never changes partial input into `not_sent`.
    ///
    /// - Parameter request: The continuation intent bound by a native token.
    /// - Returns: The recorded native-admission receipt, not editor consumption.
    /// - Throws: ``Error`` or cancellation before a paste can be admitted.
    public func continueInput(_ request: ShepherdContinuationRequest) async throws -> ShepherdAdmissionReceipt {
        guard request.hasValidText else { throw Error.invalidRequest }
        try Task.checkCancellation()
        if let prior = admission.replay(request) { return prior }
        guard let binding = admission.binding(tokenID: request.tokenID, now: now()) else { throw Error.unknownToken }
        guard let current = host.snapshot(
            workspaceID: binding.snapshot.workspaceID, surfaceID: binding.snapshot.surfaceID
        ) else {
            return admission.refuse(request, snapshot: binding.snapshot, now: now())
        }
        var calledWriter = false
        let pasted = admission.paste(
            requestID: request.requestID, token: request.tokenID, text: request.text,
            snapshot: current, now: now()
        ) {
            guard !Task.isCancelled else { return .notAdmitted }
            calledWriter = true
            return host.paste(request: request, snapshot: current, expiresAt: binding.token.expiresAt)
        }
        guard calledWriter, pasted.pasteAdmitted else { return pasted }
        defer { host.releaseReservation(requestID: request.requestID, snapshot: binding.snapshot) }
        do {
            try Task.checkCancellation()
            try await wait(0.15)
            try Task.checkCancellation()
        } catch is CancellationError {
            return try cancel(request, reason: .cancelled)
        } catch {
            return try cancel(request, reason: .waitFailed)
        }
        guard let after = host.snapshot(
            workspaceID: binding.snapshot.workspaceID, surfaceID: binding.snapshot.surfaceID
        ) else {
            return try cancel(request, reason: .targetUnavailable)
        }
        let submitted = admission.submit(requestID: request.requestID, snapshot: after, now: now()) {
            !Task.isCancelled && host.submit(requestID: request.requestID, snapshot: after)
        }
        return submitted.state == .unknown ? try cancel(request, reason: .delayNotElapsed) : submitted
    }

    /// Reads a retained outcome without retrying input or consulting a new target.
    ///
    /// - Parameter requestID: The exact request identity.
    /// - Returns: Its receipt, or nil for an unknown request, never `not_sent`.
    public func receipt(requestID: UUID) -> ShepherdAdmissionReceipt? {
        admission.receipt(requestID: requestID)
    }

    private func cancel(
        _ request: ShepherdContinuationRequest,
        reason: ShepherdAdmission.CancellationReason
    ) throws -> ShepherdAdmissionReceipt {
        guard let receipt = admission.cancel(requestID: request.requestID, reason: reason) else {
            throw Error.receiptUnavailable
        }
        return receipt
    }
}
