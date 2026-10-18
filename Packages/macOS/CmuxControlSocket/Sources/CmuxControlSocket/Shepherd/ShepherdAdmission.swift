public import Foundation

public enum ShepherdComposerState: Equatable, Sendable {
    case unknown
    case empty
    case draft(String)
    case dialog
}

public struct ShepherdAdmissionSnapshot: Equatable, Sendable {
    public var surfaceID: UUID
    public var workspaceID: UUID
    public var processInstance: String?
    public var surfaceGeneration: UInt64
    public var screenFingerprint: String
    public var outsideComposerFingerprint: String
    public var inputRevision: UInt64
    public var focusRevision: UInt64
    public var focused: Bool
    public var idle: Bool?
    public var composer: ShepherdComposerState
    public var backgroundWork: Bool?
    public var acceptsImmediateInput: Bool

    public init(
        surfaceID: UUID,
        workspaceID: UUID,
        processInstance: String?,
        surfaceGeneration: UInt64,
        screenFingerprint: String,
        outsideComposerFingerprint: String,
        inputRevision: UInt64,
        focusRevision: UInt64,
        focused: Bool,
        idle: Bool?,
        composer: ShepherdComposerState,
        backgroundWork: Bool?,
        acceptsImmediateInput: Bool
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.processInstance = processInstance
        self.surfaceGeneration = surfaceGeneration
        self.screenFingerprint = screenFingerprint
        self.outsideComposerFingerprint = outsideComposerFingerprint
        self.inputRevision = inputRevision
        self.focusRevision = focusRevision
        self.focused = focused
        self.idle = idle
        self.composer = composer
        self.backgroundWork = backgroundWork
        self.acceptsImmediateInput = acceptsImmediateInput
    }
}

public struct ShepherdObservationToken: Equatable, Sendable {
    public let id: UUID
    public let expiresAt: TimeInterval
}

public enum ShepherdAdmissionState: String, Equatable, Sendable {
    case notSent = "not_sent"
    case accepted
    case unknown
}

public struct ShepherdAdmissionReceipt: Equatable, Sendable {
    public let requestID: UUID
    public let surfaceID: UUID
    public let workspaceID: UUID
    public let processInstance: String?
    public var state: ShepherdAdmissionState
    public var reason: String
    public var pasteAdmitted: Bool
    public var submitAdmitted: Bool
}

public enum ShepherdPasteWriteResult: Equatable, Sendable {
    case notAdmitted
    case admitted(inputRevision: UInt64)
}

@MainActor
public final class ShepherdAdmission {
    private struct Observation {
        let token: ShepherdObservationToken
        let snapshot: ShepherdAdmissionSnapshot
    }

    private struct Request {
        let tokenID: UUID
        let text: String
        var receipt: ShepherdAdmissionReceipt
    }

    private struct Reservation {
        let observation: Observation
        let pastedAt: TimeInterval
        let inputRevision: UInt64
    }

    private var observations: [UUID: Observation] = [:]
    private var requests: [UUID: Request] = [:]
    private var reservations: [UUID: Reservation] = [:]

    public init() {}

    public func inspect(snapshot: ShepherdAdmissionSnapshot, now: TimeInterval) -> ShepherdObservationToken? {
        expire(at: now)
        guard now.isFinite, observations.count < 128,
              Self.isReady(snapshot), snapshot.composer == .empty,
              !reservations.values.contains(where: { $0.observation.snapshot.surfaceID == snapshot.surfaceID }) else {
            return nil
        }
        let token = ShepherdObservationToken(id: UUID(), expiresAt: now + 2)
        observations[token.id] = Observation(token: token, snapshot: snapshot)
        return token
    }

    public func paste(
        requestID: UUID,
        token: UUID,
        text: String,
        snapshot: ShepherdAdmissionSnapshot,
        now: TimeInterval,
        write: () -> ShepherdPasteWriteResult
    ) -> ShepherdAdmissionReceipt {
        expire(at: now)
        if let prior = requests[requestID] {
            guard prior.tokenID == token, prior.text == text,
                  prior.receipt.surfaceID == snapshot.surfaceID,
                  prior.receipt.workspaceID == snapshot.workspaceID else {
                var conflict = prior.receipt
                conflict.state = .unknown
                conflict.reason = "request_conflict"
                return conflict
            }
            return prior.receipt
        }
        let observation = observations.removeValue(forKey: token)
        var receipt = ShepherdAdmissionReceipt(
            requestID: requestID,
            surfaceID: snapshot.surfaceID,
            workspaceID: snapshot.workspaceID,
            processInstance: snapshot.processInstance,
            state: .notSent,
            reason: "observation_invalid",
            pasteAdmitted: false,
            submitAdmitted: false
        )
        guard requests.count < 1024 else {
            receipt.reason = "receipt_capacity"
            return receipt
        }
        requests[requestID] = Request(tokenID: token, text: text, receipt: receipt)
        guard let observation, now.isFinite, now < observation.token.expiresAt,
              observation.snapshot == snapshot, Self.isReady(snapshot), snapshot.composer == .empty,
              !reservations.values.contains(where: { $0.observation.snapshot.surfaceID == snapshot.surfaceID }),
              ShepherdContinuationRequest(requestID: requestID, tokenID: token, text: text).hasValidText else {
            return receipt
        }

        // Reserve before invoking the writer so reentrant input cannot acquire a second claim.
        receipt.state = .unknown
        receipt.reason = "paste_pending"
        requests[requestID]?.receipt = receipt
        reservations[requestID] = Reservation(observation: observation, pastedAt: now, inputRevision: snapshot.inputRevision)
        switch write() {
        case .notAdmitted:
            reservations.removeValue(forKey: requestID)
            receipt.state = .notSent
            receipt.reason = "paste_not_admitted"
        case .admitted(let inputRevision):
            reservations[requestID] = Reservation(observation: observation, pastedAt: now, inputRevision: inputRevision)
            receipt.pasteAdmitted = true
            receipt.reason = "submit_pending"
        }
        requests[requestID]?.receipt = receipt
        return receipt
    }

    public func submit(
        requestID: UUID,
        snapshot: ShepherdAdmissionSnapshot,
        now: TimeInterval,
        write: () -> Bool
    ) -> ShepherdAdmissionReceipt {
        expire(at: now)
        guard var request = requests[requestID] else {
            return ShepherdAdmissionReceipt(
                requestID: requestID,
                surfaceID: snapshot.surfaceID,
                workspaceID: snapshot.workspaceID,
                processInstance: snapshot.processInstance,
                state: .unknown,
                reason: "request_unknown",
                pasteAdmitted: false,
                submitAdmitted: false
            )
        }
        guard request.receipt.pasteAdmitted,
              let reservation = reservations[requestID] else { return request.receipt }
        guard now.isFinite, now >= reservation.pastedAt + 0.15 else { return request.receipt }
        reservations.removeValue(forKey: requestID)
        let before = reservation.observation.snapshot
        guard Self.isReady(snapshot),
              snapshot.surfaceID == before.surfaceID,
              snapshot.workspaceID == before.workspaceID,
              snapshot.processInstance == before.processInstance,
              snapshot.surfaceGeneration == before.surfaceGeneration,
              snapshot.focusRevision == before.focusRevision,
              snapshot.inputRevision == reservation.inputRevision,
              snapshot.outsideComposerFingerprint == before.outsideComposerFingerprint,
              snapshot.composer == .draft(request.text) else {
            request.receipt.reason = "paste_admitted_submit_withheld"
            requests[requestID] = request
            return request.receipt
        }
        // Consume the reservation before admitting the key, including reentrant writer calls.
        if write() {
            request.receipt.state = .accepted
            request.receipt.submitAdmitted = true
            request.receipt.reason = "paste_and_submit_admitted"
        } else {
            request.receipt.reason = "paste_admitted_submit_failed"
        }
        requests[requestID] = request
        return request.receipt
    }

    public func receipt(requestID: UUID) -> ShepherdAdmissionReceipt? {
        requests[requestID]?.receipt
    }

    private static func isReady(_ snapshot: ShepherdAdmissionSnapshot) -> Bool {
        snapshot.processInstance?.isEmpty == false &&
            !snapshot.screenFingerprint.isEmpty && !snapshot.outsideComposerFingerprint.isEmpty &&
            !snapshot.focused && snapshot.idle == true && snapshot.backgroundWork == false &&
            snapshot.acceptsImmediateInput
    }

    private func expire(at now: TimeInterval) {
        observations = observations.filter { now < $0.value.token.expiresAt }
        let expired = reservations.filter { now >= $0.value.observation.token.expiresAt }.map(\.key)
        for id in expired {
            reservations.removeValue(forKey: id)
            requests[id]?.receipt.reason = "paste_admitted_reservation_expired"
        }
    }
}
