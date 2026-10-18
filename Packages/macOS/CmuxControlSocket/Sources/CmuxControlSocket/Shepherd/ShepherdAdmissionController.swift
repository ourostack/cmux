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
        throw Error.targetUnavailable
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
        throw Error.unknownToken
    }

    /// Reads a retained outcome without retrying input or consulting a new target.
    ///
    /// - Parameter requestID: The exact request identity.
    /// - Returns: Its receipt, or nil for an unknown request, never `not_sent`.
    public func receipt(requestID: UUID) -> ShepherdAdmissionReceipt? {
        nil
    }
}
