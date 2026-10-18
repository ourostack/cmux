import Foundation
import Testing
@testable import CmuxControlSocket

@Suite(.serialized)
@MainActor
struct ShepherdAdmissionTests {
    private func idleSnapshot() -> ShepherdAdmissionSnapshot {
        ShepherdAdmissionSnapshot(
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            processInstance: "123:456",
            surfaceGeneration: 1,
            screenFingerprint: "screen-before-paste",
            outsideComposerFingerprint: "transcript-before-paste",
            inputRevision: 10,
            focusRevision: 20,
            focused: false,
            idle: true,
            composer: .empty,
            backgroundWork: false,
            acceptsImmediateInput: true
        )
    }

    @Test
    func bindingExpiresAndReplayDoesNotNeedNewLiveEvidence() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        #expect(gate.binding(tokenID: token.id, now: 100.1)?.snapshot == snapshot)
        let intent = ShepherdContinuationRequest(requestID: UUID(), tokenID: token.id, text: "continue")
        let first = gate.paste(
            requestID: intent.requestID, token: intent.tokenID, text: intent.text,
            snapshot: snapshot, now: 100.2
        ) { .admitted(inputRevision: 11) }
        #expect(gate.replay(intent) == first)
        #expect(gate.binding(tokenID: token.id, now: 100.3) == nil)
        let changed = ShepherdContinuationRequest(requestID: intent.requestID, tokenID: UUID(), text: intent.text)
        #expect(gate.replay(changed)?.reason == "request_conflict")
        #expect(gate.receipt(requestID: intent.requestID) == first)
        let expiryGate = ShepherdAdmission()
        let fresh = try #require(expiryGate.inspect(snapshot: snapshot, now: 100))
        #expect(expiryGate.binding(tokenID: fresh.id, now: 101)?.token == fresh)
        #expect(expiryGate.binding(tokenID: fresh.id, now: 102) == nil)
    }

    @Test
    func zeroInputRefusalIsRetainedAndCannotLaterPaste() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        let intent = ShepherdContinuationRequest(requestID: UUID(), tokenID: token.id, text: "continue")
        let refused = gate.refuse(intent, snapshot: snapshot, now: 100.1)
        #expect(refused.state == .notSent && !refused.pasteAdmitted)
        #expect(gate.receipt(requestID: intent.requestID) == refused)
        let retry = gate.paste(
            requestID: intent.requestID, token: intent.tokenID, text: intent.text,
            snapshot: snapshot, now: 100.2
        ) {
            Issue.record("A recorded zero-input refusal must not turn into a later paste.")
            return .admitted(inputRevision: 11)
        }
        #expect(retry == refused)
    }

    @Test
    func cancellationConsumesTheSubmitReservation() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let id = UUID()
        _ = gate.paste(requestID: id, token: token.id, text: "continue", snapshot: before, now: 100.1) {
            .admitted(inputRevision: 11)
        }
        #expect(gate.cancel(requestID: id)?.reason == ShepherdAdmission.CancellationReason.cancelled.rawValue)
        var after = before
        after.composer = .draft("continue")
        after.inputRevision = 11
        var submits = 0
        let final = gate.submit(requestID: id, snapshot: after, now: 100.3) {
            submits += 1
            return true
        }
        #expect(final.state == .unknown && final.pasteAdmitted && !final.submitAdmitted)
        #expect(submits == 0)
    }

    @Test
    func reentrantCancellationCannotReopenThePendingWriterOrResurrectSubmit() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let other = try #require(gate.inspect(snapshot: before, now: 100))
        let id = UUID()
        var otherPastes = 0
        let first = gate.paste(requestID: id, token: token.id, text: "continue", snapshot: before, now: 100.1) {
            _ = gate.cancel(requestID: id)
            let nested = gate.paste(
                requestID: UUID(), token: other.id, text: "other", snapshot: before, now: 100.1
            ) {
                otherPastes += 1
                return .admitted(inputRevision: 11)
            }
            #expect(nested.state == .notSent)
            return .admitted(inputRevision: 11)
        }
        #expect(first.reason == ShepherdAdmission.CancellationReason.cancelled.rawValue)
        var after = before
        after.composer = .draft("continue")
        after.inputRevision = 11
        var submits = 0
        _ = gate.submit(requestID: id, snapshot: after, now: 100.3) {
            submits += 1
            return true
        }
        #expect(otherPastes == 0 && submits == 0)
    }

    @Test
    func expiryDuringPasteCannotReopenThePendingWriter() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        var otherPastes = 0
        let first = gate.paste(requestID: UUID(), token: token.id, text: "continue", snapshot: before, now: 100.1) {
            let reopened = gate.inspect(snapshot: before, now: 103)
            #expect(reopened == nil)
            if let reopened {
                _ = gate.paste(
                    requestID: UUID(), token: reopened.id, text: "other", snapshot: before, now: 103.1
                ) {
                    otherPastes += 1
                    return .admitted(inputRevision: 11)
                }
            }
            return .admitted(inputRevision: 11)
        }
        #expect(first.state == .unknown && first.pasteAdmitted && !first.submitAdmitted)
        #expect(otherPastes == 0)
    }

    @Test
    func unverifiablePaddingIsRefusedBeforePaste() throws {
        for text in [" ", " leading", "trailing "] {
            let gate = ShepherdAdmission()
            let snapshot = idleSnapshot()
            let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
            var pastes = 0
            let receipt = gate.paste(
                requestID: UUID(), token: token.id, text: text,
                snapshot: snapshot, now: 100.1
            ) {
                pastes += 1
                return .admitted(inputRevision: 11)
            }
            #expect(receipt.state == .notSent)
            #expect(pastes == 0)
        }
    }

    @Test
    func expiredTokenRefusesBeforeInput() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        var pastes = 0
        let receipt = gate.paste(
            requestID: UUID(), token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: snapshot, now: 102
        ) {
            pastes += 1
            return .admitted(inputRevision: 11)
        }
        #expect(receipt.state == .notSent)
        #expect(pastes == 0)
    }

    @Test(arguments: ["focus", "input", "screen", "process", "surface", "workspace", "generation", "draft", "working", "background", "deferred"])
    func changedEvidenceRefusesBeforeInput(change: String) throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        var changed = snapshot
        switch change {
        case "focus": changed.focusRevision += 1
        case "input": changed.inputRevision += 1
        case "screen": changed.screenFingerprint = "other-screen"
        case "process": changed.processInstance = "123:999"
        case "surface": changed.surfaceID = UUID()
        case "workspace": changed.workspaceID = UUID()
        case "generation": changed.surfaceGeneration += 1
        case "draft": changed.composer = .draft("human text")
        case "working": changed.idle = false
        case "background": changed.backgroundWork = true
        default: changed.acceptsImmediateInput = false
        }
        var pastes = 0
        let receipt = gate.paste(
            requestID: UUID(), token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: changed, now: 100.1
        ) {
            pastes += 1
            return .admitted(inputRevision: 11)
        }
        #expect(receipt.state == .notSent)
        #expect(pastes == 0)
    }

    @Test
    func stableComposerSubmitsExactlyOnce() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        var pastes = 0
        let pasted = gate.paste(
            requestID: request, token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: before, now: 100.1
        ) {
            pastes += 1
            return .admitted(inputRevision: 11)
        }
        #expect(pasted.state == .unknown)
        #expect(pasted.pasteAdmitted)
        #expect(!pasted.submitAdmitted)
        var after = before
        after.screenFingerprint = "screen-with-own-draft"
        after.composer = .draft("[Ouro] Continue authorized work.")
        after.inputRevision = 11
        var submits = 0
        let sent = gate.submit(requestID: request, snapshot: after, now: 100.3) {
            submits += 1
            return true
        }
        #expect(sent.state == .accepted)
        #expect(sent.pasteAdmitted)
        #expect(sent.submitAdmitted)
        let duplicate = gate.submit(requestID: request, snapshot: after, now: 100.4) {
            submits += 1
            return true
        }
        #expect(duplicate == sent)
        #expect(gate.receipt(requestID: request) == sent)
        #expect(pastes == 1)
        #expect(submits == 1)
    }

    @Test(arguments: ["focus", "input", "process", "transcript", "draft", "deadline", "working", "deferred"])
    func invalidationAfterPasteNeverSubmitsOrClaimsNotSent(change: String) throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        _ = gate.paste(
            requestID: request, token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: before, now: 100.1
        ) { .admitted(inputRevision: 11) }
        var after = before
        after.screenFingerprint = "screen-with-own-draft"
        after.composer = .draft("[Ouro] Continue authorized work.")
        after.inputRevision = 11
        switch change {
        case "focus": after.focusRevision += 1
        case "input": after.inputRevision += 1
        case "process": after.processInstance = "123:999"
        case "transcript": after.outsideComposerFingerprint = "new-output"
        case "draft": after.composer = .draft("[Ouro] Continue authorized work. human edit")
        case "working": after.idle = false
        case "deferred": after.acceptsImmediateInput = false
        default: break
        }
        var submits = 0
        let receipt = gate.submit(
            requestID: request, snapshot: after, now: change == "deadline" ? 102 : 100.3
        ) {
            submits += 1
            return true
        }
        #expect(receipt.state == .unknown)
        #expect(receipt.pasteAdmitted)
        #expect(!receipt.submitAdmitted)
        #expect(submits == 0)
    }

    @Test
    func duplicateRequestAndConsumedTokenCannotPasteTwice() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        let request = UUID()
        var pastes = 0
        let first = gate.paste(
            requestID: request, token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: snapshot, now: 100.1
        ) {
            pastes += 1
            return .admitted(inputRevision: 11)
        }
        let duplicate = gate.paste(
            requestID: request, token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: snapshot, now: 100.2
        ) {
            pastes += 1
            return .admitted(inputRevision: 12)
        }
        let anotherRequest = gate.paste(
            requestID: UUID(), token: token.id, text: "[Ouro] Other work.",
            snapshot: snapshot, now: 100.2
        ) {
            pastes += 1
            return .admitted(inputRevision: 12)
        }
        #expect(duplicate == first)
        #expect(anotherRequest.state == .notSent)
        #expect(pastes == 1)
    }

    @Test
    func rejectedPasteIsDefinitelyNotSentButFailedSubmitIsUnknown() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        let rejected = gate.paste(
            requestID: UUID(), token: token.id, text: "[Ouro] Continue authorized work.",
            snapshot: snapshot, now: 100.1
        ) { .notAdmitted }
        #expect(rejected.state == .notSent)
        #expect(!rejected.pasteAdmitted)

        let next = try #require(gate.inspect(snapshot: snapshot, now: 100.2))
        let request = UUID()
        _ = gate.paste(
            requestID: request, token: next.id, text: "[Ouro] Continue authorized work.",
            snapshot: snapshot, now: 100.3
        ) { .admitted(inputRevision: 11) }
        var after = snapshot
        after.composer = .draft("[Ouro] Continue authorized work.")
        after.inputRevision = 11
        let failed = gate.submit(requestID: request, snapshot: after, now: 100.5) { false }
        #expect(failed.state == .unknown)
        #expect(failed.pasteAdmitted)
        #expect(!failed.submitAdmitted)
    }

    @Test
    func submitCannotReenterAnUnfinishedPasteWriter() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        var after = before
        after.composer = .draft("continue")
        var submits = 0
        let receipt = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: before, now: 100.1
        ) {
            _ = gate.submit(requestID: request, snapshot: after, now: 100.3) {
                submits += 1
                return true
            }
            return .notAdmitted
        }
        #expect(receipt.state == .notSent)
        #expect(!receipt.pasteAdmitted)
        #expect(submits == 0)
    }

    @Test
    func retryKeepsTheOriginalReceiptWhenOnlyLiveEvidenceChanged() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        let first = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: before, now: 100.1
        ) { .admitted(inputRevision: 11) }
        var changed = before
        changed.processInstance = "999:999"
        changed.surfaceGeneration += 1
        changed.inputRevision += 1
        let duplicate = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: changed, now: 100.2
        ) {
            Issue.record("A receipt retry must not admit input.")
            return .notAdmitted
        }
        #expect(duplicate == first)
        #expect(duplicate.processInstance == before.processInstance)
    }

    @Test(arguments: ["surface", "workspace"])
    func conflictingTargetCannotReuseAnAcceptedReceipt(change: String) throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        var pastes = 0
        _ = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: before, now: 100.1
        ) {
            pastes += 1
            return .admitted(inputRevision: 11)
        }
        var after = before
        after.composer = .draft("continue")
        after.inputRevision = 11
        var submits = 0
        let accepted = gate.submit(requestID: request, snapshot: after, now: 100.3) {
            submits += 1
            return true
        }
        #expect(accepted.state == .accepted)
        var otherTarget = before
        if change == "surface" {
            otherTarget.surfaceID = UUID()
        } else {
            otherTarget.workspaceID = UUID()
        }
        let conflict = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: otherTarget, now: 100.4
        ) {
            pastes += 1
            return .admitted(inputRevision: 12)
        }
        #expect(conflict.state == .unknown)
        #expect(conflict.reason == "request_conflict")
        #expect(gate.receipt(requestID: request) == accepted)
        #expect(pastes == 1)
        #expect(submits == 1)
    }

    @Test
    func conflictingPayloadCannotChangeTheStoredReceipt() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        let request = UUID()
        let first = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: snapshot, now: 100.1
        ) { .admitted(inputRevision: 11) }
        var writes = 0
        let conflict = gate.paste(
            requestID: request, token: token.id, text: "different",
            snapshot: snapshot, now: 100.2
        ) {
            writes += 1
            return .admitted(inputRevision: 12)
        }
        #expect(conflict.state == .unknown)
        #expect(conflict.reason == "request_conflict")
        #expect(gate.receipt(requestID: request) == first)
        #expect(writes == 0)
    }

    @Test
    func earlySubmitPreservesReservationUntilRequiredSeparation() throws {
        let gate = ShepherdAdmission()
        let before = idleSnapshot()
        let token = try #require(gate.inspect(snapshot: before, now: 100))
        let request = UUID()
        _ = gate.paste(
            requestID: request, token: token.id, text: "continue",
            snapshot: before, now: 100.1
        ) { .admitted(inputRevision: 11) }
        var after = before
        after.composer = .draft("continue")
        after.inputRevision = 11
        var submits = 0
        let early = gate.submit(requestID: request, snapshot: after, now: 100.2) {
            submits += 1
            return true
        }
        #expect(early.state == .unknown)
        #expect(submits == 0)
        let ready = gate.submit(requestID: request, snapshot: after, now: 100.3) {
            submits += 1
            return true
        }
        #expect(ready.state == .accepted)
        #expect(submits == 1)
    }

    @Test
    func boundedReceiptCapacityRefusesWithoutDiscardingReplayBarriers() throws {
        let gate = ShepherdAdmission()
        let snapshot = idleSnapshot()
        var firstRequest: UUID?
        for _ in 0..<1024 {
            let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
            let request = UUID()
            firstRequest = firstRequest ?? request
            _ = gate.paste(
                requestID: request, token: token.id, text: "continue",
                snapshot: snapshot, now: 100.1
            ) { .notAdmitted }
        }
        let token = try #require(gate.inspect(snapshot: snapshot, now: 100))
        var writes = 0
        let refused = gate.paste(
            requestID: UUID(), token: token.id, text: "continue",
            snapshot: snapshot, now: 100.1
        ) {
            writes += 1
            return .admitted(inputRevision: 11)
        }
        #expect(refused.reason == "receipt_capacity")
        #expect(refused.state == .notSent)
        #expect(gate.receipt(requestID: try #require(firstRequest)) != nil)
        #expect(writes == 0)
    }
}
