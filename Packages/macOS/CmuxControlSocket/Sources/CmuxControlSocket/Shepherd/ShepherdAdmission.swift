public import Foundation

/// A bounded native observation and receipt owner that fails closed at capacity.
///
/// Keep one owner for a native host lifetime. It refuses new requests rather
/// than evicting the 1,024 retained replay outcomes or granting input from
/// unknown readiness. Actual transport and current facts remain host duties.
@MainActor
public final class ShepherdAdmission {
    /// Why an unfinished submission is being withheld.
    public enum CancellationReason: String, Sendable {
        /// The owning operation was cancelled.
        case cancelled = "request_cancelled"
        /// The original target is no longer observable.
        case targetUnavailable = "paste_admitted_target_unavailable"
        /// The minimum-delay operation failed.
        case waitFailed = "paste_admitted_wait_failed"
        /// The delay returned before the required minimum elapsed.
        case delayNotElapsed = "paste_admitted_minimum_delay_unmet"
        /// The original observation expired before submission.
        case expired = "paste_admitted_reservation_expired"
    }

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
        var cancellationReason: CancellationReason?
    }

    private var observations: [UUID: Observation] = [:]
    private var requests: [UUID: Request] = [:]
    private var reservations: [UUID: Reservation] = [:]

    /// Creates an empty boot-local observation and receipt ledger.
    public init() {}

    /// Issues a one-use, two-second token only for a ready, empty target.
    ///
    /// - Parameters:
    ///   - snapshot: Current native evidence, never terminal-provided authority.
    ///   - now: Current host uptime.
    /// - Returns: A token, or nil for unknown, busy, focused or capacity-limited state.
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

    /// Admits one literal paste only when fresh evidence still matches its token.
    ///
    /// - Parameters:
    ///   - requestID: The stable identity for these exact arguments and target.
    ///   - token: The one-use native observation identity.
    ///   - text: Exact, bounded, canonical single-line input.
    ///   - snapshot: Current native evidence for the intended target.
    ///   - now: Current host uptime.
    ///   - write: An immediate writer; `.notAdmitted` must prove zero input.
    /// - Returns: A recorded refusal, partial outcome, replay or conflict.
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
            guard prior.tokenID == token, prior.text.utf8.elementsEqual(text.utf8),
                  prior.receipt.surfaceID == snapshot.surfaceID,
                  prior.receipt.workspaceID == snapshot.workspaceID else {
                return conflictReceipt(prior.receipt)
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
            receipt.pasteAdmitted = true
            if let pending = reservations.removeValue(forKey: requestID) {
                if let reason = pending.cancellationReason {
                    receipt.reason = reason.rawValue
                } else {
                    reservations[requestID] = Reservation(
                        observation: pending.observation, pastedAt: pending.pastedAt, inputRevision: inputRevision
                    )
                    receipt.reason = "submit_pending"
                }
            } else {
                receipt.reason = "paste_admitted_reservation_lost"
            }
        }
        requests[requestID]?.receipt = receipt
        return receipt
    }

    /// Consumes a reservation only after the minimum delay and exact recheck.
    ///
    /// - Parameters:
    ///   - requestID: The request that admitted the paste.
    ///   - snapshot: Current native facts and the exact inserted composer.
    ///   - now: Current host uptime.
    ///   - write: An immediate native Enter writer that never queues input.
    /// - Returns: The retained outcome; partial or uncertain input stays unknown.
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
              case .draft(let text) = snapshot.composer,
              text.utf8.elementsEqual(request.text.utf8) else {
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

    /// Reads a retained outcome without replaying input.
    ///
    /// - Parameter requestID: The exact request identity.
    /// - Returns: Its recorded receipt, or nil rather than an invented no-send.
    public func receipt(requestID: UUID) -> ShepherdAdmissionReceipt? {
        requests[requestID]?.receipt
    }

    /// Reads original token scope; this historical snapshot never permits input.
    ///
    /// - Parameters:
    ///   - tokenID: An observation token.
    ///   - now: Current host uptime.
    /// - Returns: The original binding only while the token is active.
    public func binding(
        tokenID: UUID,
        now: TimeInterval
    ) -> (token: ShepherdObservationToken, snapshot: ShepherdAdmissionSnapshot)? {
        guard now.isFinite else { return nil }
        expire(at: now)
        guard let observation = observations[tokenID] else { return nil }
        return (observation.token, observation.snapshot)
    }

    /// Reconciles an existing request without a fresh write or new target.
    ///
    /// - Parameter request: The exact continuation intent.
    /// - Returns: Its prior result or a conflict, or nil for an unknown request.
    public func replay(_ request: ShepherdContinuationRequest) -> ShepherdAdmissionReceipt? {
        guard let prior = requests[request.requestID] else { return nil }
        guard prior.tokenID == request.tokenID, prior.text.utf8.elementsEqual(request.text.utf8) else {
            return conflictReceipt(prior.receipt)
        }
        return prior.receipt
    }

    /// Records a zero-input refusal using an observed target's historical scope.
    ///
    /// This must never invoke a real writer or treat the old snapshot as current
    /// permission. Existing outcomes, including accepted ones, remain unchanged.
    ///
    /// - Parameters:
    ///   - request: The intent being refused before input.
    ///   - snapshot: The original token-bound target.
    ///   - now: Current host uptime.
    /// - Returns: The refusal or an already-recorded outcome.
    public func refuse(
        _ request: ShepherdContinuationRequest,
        snapshot: ShepherdAdmissionSnapshot,
        now: TimeInterval
    ) -> ShepherdAdmissionReceipt {
        paste(
            requestID: request.requestID, token: request.tokenID, text: request.text,
            snapshot: snapshot, now: now
        ) { .notAdmitted }
    }

    /// Withholds an unfinished submit without rewriting already-known outcomes.
    ///
    /// - Parameters:
    ///   - requestID: The request whose reservation should end.
    ///   - reason: A bounded, explicit cancellation cause.
    /// - Returns: The retained outcome, or nil when the request is unknown.
    public func cancel(
        requestID: UUID,
        reason: CancellationReason = .cancelled
    ) -> ShepherdAdmissionReceipt? {
        guard var request = requests[requestID] else { return nil }
        guard var reservation = reservations[requestID] else { return request.receipt }
        let retainedReason = reservation.cancellationReason ?? reason
        if request.receipt.pasteAdmitted {
            reservations.removeValue(forKey: requestID)
        } else {
            // A reentrant cancel cannot free a writer that has not returned yet.
            reservation.cancellationReason = retainedReason
            reservations[requestID] = reservation
        }
        request.receipt.state = .unknown
        request.receipt.reason = retainedReason.rawValue
        requests[requestID] = request
        return request.receipt
    }

    private func conflictReceipt(_ receipt: ShepherdAdmissionReceipt) -> ShepherdAdmissionReceipt {
        var conflict = receipt
        conflict.state = .unknown
        conflict.reason = "request_conflict"
        return conflict
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
            _ = cancel(requestID: id, reason: .expired)
        }
    }
}
