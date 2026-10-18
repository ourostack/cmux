public import Foundation
internal import CryptoKit

/// One native boot's strict wire boundary and shared admission owner.
///
/// Creating this service does not qualify a host. Its host must report actual
/// native facts and enforce the immediate-input reservation at each write.
@MainActor
public final class ShepherdControlBoundary {
    /// The native boot identity retained across all socket clients.
    public let hostInstance: UUID

    private let controller: ShepherdAdmissionController
    private let now: @MainActor () -> TimeInterval
    private let unixMilliseconds: @MainActor () -> Int64
    private let readVisibleScreen: @MainActor (UUID, UUID) -> String?

    /// Creates the single admission owner for a native host's lifetime.
    ///
    /// Both the host's reservation deadlines and `now` must use uptime seconds.
    /// `readVisibleScreen` must synchronously capture the exact target's raw
    /// visible text whose UTF-8 SHA-256 is the snapshot's screen fingerprint.
    public init(
        host: any ShepherdAdmissionHost,
        hostInstance: UUID = UUID(),
        now: @escaping @MainActor () -> TimeInterval,
        unixMilliseconds: @escaping @MainActor () -> Int64,
        readVisibleScreen: @escaping @MainActor (UUID, UUID) -> String?,
        wait: @escaping @MainActor (TimeInterval) async throws -> Void
    ) {
        self.hostInstance = hostInstance
        self.now = now
        self.unixMilliseconds = unixMilliseconds
        self.readVisibleScreen = readVisibleScreen
        controller = ShepherdAdmissionController(host: host, now: now, wait: wait)
    }

    /// Authorizes provenance before hopping to the native actor or reading state.
    ///
    /// The connection owner must cancel this task on disconnect/revocation.
    /// A cancellation after paste returns the retained partial-effect receipt.
    public nonisolated func handle(
        _ request: ControlRequest, peer: ShepherdControlPeer?
    ) async -> ControlCallResult {
        if let rejection = rejection(for: request, peer: peer) { return rejection }
        do {
            let decoded = try ShepherdControlRequest(request: request)
            return await execute(decoded)
        } catch {
            return failure("invalid_params", "Invalid native Shepherd parameters.")
        }
    }

    /// Serves reads without introducing a blocking paste/delay/submit path.
    public func handleSynchronously(
        _ request: ControlRequest, peer: ShepherdControlPeer?
    ) -> ControlCallResult {
        if let rejection = rejection(for: request, peer: peer) { return rejection }
        do {
            let decoded = try ShepherdControlRequest(request: request)
            switch decoded {
            case .inspect(let workspace, let surface):
                return try inspection(workspaceID: workspace, surfaceID: surface)
            case .receipt(let id):
                return receipt(requestID: id)
            case .continueInput:
                return failure("async_required", "Native continuation requires a cancellable connection task.")
            }
        } catch let error as ShepherdAdmissionController.Error {
            return controllerFailure(error)
        } catch {
            return failure("invalid_params", "Invalid native Shepherd parameters.")
        }
    }

    private nonisolated var metadata: [String: JSONValue] {
        ["protocol_version": .int(1), "host_instance": .string(hostInstance.uuidString)]
    }

    private nonisolated func rejection(
        for request: ControlRequest, peer: ShepherdControlPeer?
    ) -> ControlCallResult? {
        guard ShepherdControlRequest.Method(rawValue: request.method) != nil else {
            return failure("method_not_found", "Not a native Shepherd method.")
        }
        guard let peer, peer.peerHasSameUID, !peer.isRemoteRelay else {
            return failure("access_denied", "Native Shepherd requires a verified same-user local peer.")
        }
        return nil
    }

    private func execute(_ request: ShepherdControlRequest) async -> ControlCallResult {
        do {
            try Task.checkCancellation()
            switch request {
            case .inspect(let workspace, let surface):
                return try inspection(workspaceID: workspace, surfaceID: surface)
            case .receipt(let id):
                return receipt(requestID: id)
            case .continueInput(let intent):
                return .ok(.object(encode(try await controller.continueInput(intent))))
            }
        } catch is CancellationError {
            return failure("cancelled", "The native request was cancelled before an input outcome was recorded.")
        } catch let error as ShepherdAdmissionController.Error {
            return controllerFailure(error)
        } catch {
            return failure("internal_error", "Native Shepherd could not establish an input outcome.")
        }
    }

    private func inspection(workspaceID: UUID, surfaceID: UUID) throws -> ControlCallResult {
        let observedAt = now()
        let unix = unixMilliseconds()
        guard observedAt.isFinite, observedAt >= 0, unix >= 0 else {
            return failure("clock_unavailable", "Native observation clocks are unavailable.")
        }
        let inspected = try controller.inspect(workspaceID: workspaceID, surfaceID: surfaceID)
        let raw = readVisibleScreen(workspaceID, surfaceID)
        let canonical = raw.flatMap { text -> String? in
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            return hash == inspected.snapshot.screenFingerprint ? text : nil
        }
        var value = metadata
        value["snapshot"] = .object(encode(inspected.snapshot))
        value["screen"] = canonical.map(JSONValue.string) ?? .null
        value["observed_at_uptime_seconds"] = .double(observedAt)
        value["observed_at_unix_ms"] = .int(unix)
        let capturedAt = now()
        if canonical != nil, capturedAt.isFinite, capturedAt >= observedAt,
           let token = inspected.token, token.expiresAt.isFinite, token.expiresAt > capturedAt {
            value["token"] = .object([
                "id": .string(token.id.uuidString),
                "expires_at_uptime_seconds": .double(token.expiresAt)
            ])
        } else {
            value["token"] = .null
        }
        return .ok(.object(value))
    }

    private func receipt(requestID: UUID) -> ControlCallResult {
        guard let recorded = controller.receipt(requestID: requestID) else {
            return failure("not_found", "No receipt is retained for this native request.")
        }
        return .ok(.object(encode(recorded)))
    }

    private func encode(_ snapshot: ShepherdAdmissionSnapshot) -> [String: JSONValue] {
        [
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "surface_id": .string(snapshot.surfaceID.uuidString),
            "process_instance": snapshot.processInstance.map(JSONValue.string) ?? .null,
            "surface_generation": integer(snapshot.surfaceGeneration),
            "screen_fingerprint": .string(snapshot.screenFingerprint),
            "outside_composer_fingerprint": .string(snapshot.outsideComposerFingerprint),
            "input_revision": integer(snapshot.inputRevision), "focus_revision": integer(snapshot.focusRevision),
            "focused": .bool(snapshot.focused),
            "idle": snapshot.idle.map(JSONValue.bool) ?? .null,
            "composer": .object(encode(snapshot.composer)),
            "background_work": snapshot.backgroundWork.map(JSONValue.bool) ?? .null,
            "accepts_immediate_input": .bool(snapshot.acceptsImmediateInput)
        ]
    }

    private func encode(_ composer: ShepherdComposerState) -> [String: JSONValue] {
        switch composer {
        case .unknown: return ["state": .string("unknown"), "draft_length": .null]
        case .empty: return ["state": .string("empty"), "draft_length": .int(0)]
        case .dialog: return ["state": .string("dialog"), "draft_length": .null]
        case .draft(let text): return ["state": .string("draft"), "draft_length": .int(Int64(text.count))]
        }
    }

    private func encode(_ receipt: ShepherdAdmissionReceipt) -> [String: JSONValue] {
        var value = metadata
        value["request_id"] = .string(receipt.requestID.uuidString)
        value["workspace_id"] = .string(receipt.workspaceID.uuidString)
        value["surface_id"] = .string(receipt.surfaceID.uuidString)
        value["process_instance"] = receipt.processInstance.map(JSONValue.string) ?? .null
        value["state"] = .string(receipt.state.rawValue)
        value["reason"] = .string(receipt.reason)
        value["paste_admitted"] = .bool(receipt.pasteAdmitted)
        value["submit_admitted"] = .bool(receipt.submitAdmitted)
        return value
    }

    private func integer(_ value: UInt64) -> JSONValue {
        Int64(exactly: value).map(JSONValue.int) ?? .decimal(String(value))
    }

    private func controllerFailure(_ error: ShepherdAdmissionController.Error) -> ControlCallResult {
        switch error {
        case .invalidRequest: return failure("invalid_params", "Invalid native Shepherd continuation.")
        case .unknownToken: return failure("unknown_token", "No live native observation binds this token.")
        case .targetUnavailable: return failure("target_unavailable", "The exact native target cannot be observed.")
        case .receiptUnavailable: return failure("receipt_unavailable", "The native input outcome is unavailable.")
        }
    }

    private nonisolated func failure(_ code: String, _ message: String) -> ControlCallResult {
        .err(code: code, message: message, data: .object(metadata))
    }
}
