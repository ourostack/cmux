public import Foundation

/// The strictly decoded commands for the local native Shepherd boundary.
public enum ShepherdControlRequest: Equatable, Sendable {
    /// An exact workspace and surface to inspect without changing focus.
    case inspect(workspaceID: UUID, surfaceID: UUID)
    /// A plain-text continuation bound to an opaque native observation token.
    case continueInput(ShepherdContinuationRequest)
    /// A read of an existing request's receipt, never a retry.
    case receipt(requestID: UUID)

    /// Canonical wire method names; discovery must use these declarations.
    public enum Method: String, CaseIterable, Sendable {
        /// Reads native state and may issue a short-lived observation token.
        case inspect = "surface.shepherd.inspect"
        /// Requests guarded literal paste and submission.
        case continueInput = "surface.shepherd.continue"
        /// Reads an existing request's outcome without admitting input.
        case receipt = "surface.shepherd.receipt"
    }

    /// Argument-decoding failures that never authorize terminal input.
    public enum Error: Swift.Error, Equatable, Sendable {
        /// The method is not part of this boundary.
        case unsupportedMethod
        /// An argument is missing, unknown, mistyped or unsafe.
        case invalidParameters
    }

    /// The canonical method corresponding to this decoded operation.
    public var method: Method {
        switch self {
        case .inspect: .inspect
        case .continueInput: .continueInput
        case .receipt: .receipt
        }
    }

    /// Decodes exact UUID targets and bounded, canonical single-line text.
    ///
    /// This validates data, not caller authority. The socket entry point must
    /// independently require a same-UID local caller and deny remote relays.
    ///
    /// - Parameter request: The decoded v2 envelope.
    /// - Throws: ``Error`` when the method or arguments are invalid.
    public init(request: ControlRequest) throws {
        throw Error.unsupportedMethod
    }
}
