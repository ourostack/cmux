import Foundation
import Testing
@testable import CmuxControlSocket

@Suite(.serialized)
@MainActor
struct ShepherdAdmissionControllerTests {
    private enum WaitFailure: Error { case failed }

    private func setup() -> (
        controller: ShepherdAdmissionController,
        host: ShepherdAdmissionHostProbe,
        clock: ShepherdAdmissionClockProbe
    ) {
        let host = ShepherdAdmissionHostProbe()
        let clock = ShepherdAdmissionClockProbe()
        let controller = ShepherdAdmissionController(
            host: host, now: { clock.now }, wait: { try await clock.wait($0) }
        )
        return (controller, host, clock)
    }

    private func token(
        _ controller: ShepherdAdmissionController,
        _ host: ShepherdAdmissionHostProbe
    ) throws -> ShepherdObservationToken {
        let snapshot = try #require(host.current)
        return try #require(controller.inspect(
            workspaceID: snapshot.workspaceID, surfaceID: snapshot.surfaceID
        ).token)
    }

    private func request(_ token: UUID, text: String = "Continue the authorized task.") -> ShepherdContinuationRequest {
        ShepherdContinuationRequest(requestID: UUID(), tokenID: token, text: text)
    }

    @Test
    func sequencesOnePasteThenMinimumDelayFreshReadAndSubmit() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        clock.now = 101
        let intent = request(observed.id)
        let result = try await controller.continueInput(intent)
        #expect(result.state == .accepted)
        #expect(result.pasteAdmitted && result.submitAdmitted)
        #expect(clock.waits == [0.15])
        #expect(host.lastDeadline == observed.expiresAt)
        #expect(host.events == ["read", "read", "paste", "read", "submit", "release"])
        #expect(host.released == [intent.requestID])
        #expect(controller.receipt(requestID: intent.requestID) == result)
    }

    @Test(arguments: ["idle", "background", "composer", "immediate"])
    func unknownReadinessNeverIssuesAToken(change: String) throws {
        let (controller, host, _) = setup()
        let initial = try #require(host.current)
        switch change {
        case "idle": host.current?.idle = nil
        case "background": host.current?.backgroundWork = nil
        case "composer": host.current?.composer = .unknown
        default: host.current?.acceptsImmediateInput = false
        }
        let inspected = try controller.inspect(workspaceID: initial.workspaceID, surfaceID: initial.surfaceID)
        #expect(inspected.token == nil)
        #expect(host.pasteCalls == 0)
    }

    @Test(arguments: ["agent", "cwd", "tty"])
    func unknownNativeProcessScopeNeverIssuesAToken(field: String) throws {
        let (controller, host, _) = setup()
        let target = try #require(host.current)
        for missing: String? in [nil, ""] {
            switch field {
            case "agent": host.current?.agent = missing
            case "cwd": host.current?.workingDirectory = missing
            default: host.current?.tty = missing
            }
            #expect(try controller.inspect(workspaceID: target.workspaceID, surfaceID: target.surfaceID).token == nil)
        }
        #expect(host.pasteCalls == 0)
    }

    @Test(arguments: ["agent", "cwd", "tty"])
    func sameProcessScopeChangingBeforePasteAdmitsZeroInput(field: String) async throws {
        let (controller, host, _) = setup()
        let observed = try token(controller, host)
        switch field {
        case "agent": host.current?.agent = "Codex"
        case "cwd": host.current?.workingDirectory = "/other/project"
        default: host.current?.tty = "/dev/ttys009"
        }
        let result = try await controller.continueInput(request(observed.id))
        #expect(result.state == .notSent)
        #expect(!result.pasteAdmitted && !result.submitAdmitted)
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
    }

    @Test
    func refusesMissingOrMismatchedInspectionTargets() throws {
        let (controller, host, _) = setup()
        let initial = try #require(host.current)
        #expect(throws: ShepherdAdmissionController.Error.targetUnavailable) {
            try controller.inspect(workspaceID: UUID(), surfaceID: initial.surfaceID)
        }
        host.current = nil
        #expect(throws: ShepherdAdmissionController.Error.targetUnavailable) {
            try controller.inspect(workspaceID: initial.workspaceID, surfaceID: initial.surfaceID)
        }
        #expect(host.pasteCalls == 0)
    }

    @Test
    func targetDisappearingBeforePasteRetainsAZeroInputReceipt() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        host.current = nil
        let result = try await controller.continueInput(intent)
        #expect(result.state == .notSent)
        #expect(!result.pasteAdmitted && !result.submitAdmitted)
        #expect(controller.receipt(requestID: intent.requestID) == result)
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
        #expect(clock.waits.isEmpty && host.released.isEmpty)
        #expect(try await controller.continueInput(intent) == result)
    }

    @Test
    func rechecksBeforePasteAndDoesNotExtendTheOriginalDeadline() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        host.current?.inputRevision += 1
        let result = try await controller.continueInput(request(observed.id))
        #expect(result.state == .notSent)
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
        #expect(clock.waits.isEmpty)
    }

    @Test(arguments: ["focus", "input", "process", "background", "outside", "target", "scope", "agent", "cwd", "tty"])
    func postPasteChangesWithholdSubmitAndKeepPartialInput(change: String) async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        clock.action = { seconds in
            clock.now += seconds
            switch change {
            case "focus": host.current?.focused = true
            case "input": host.current?.inputRevision += 1
            case "process": host.current?.processInstance = "999:999"
            case "background": host.current?.backgroundWork = true
            case "outside": host.current?.outsideComposerFingerprint = "new-output"
            case "scope": host.current?.workspaceID = UUID()
            case "agent": host.current?.agent = "Codex"
            case "cwd": host.current?.workingDirectory = "/other/project"
            case "tty": host.current?.tty = "/dev/ttys009"
            default: host.current = nil
            }
        }
        let result = try await controller.continueInput(intent)
        #expect(result.state == .unknown)
        #expect(result.pasteAdmitted && !result.submitAdmitted)
        #expect(host.pasteCalls == 1 && host.submitCalls == 0)
        #expect(host.released == [intent.requestID])
        #expect(controller.receipt(requestID: intent.requestID) == result)
    }

    @Test
    func cancellationAfterPasteNeverBecomesNotSentOrRetries() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        clock.action = { seconds in
            clock.now += seconds
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let operation = Task { try await controller.continueInput(intent) }
        let result = try await operation.value
        #expect(result.state == .unknown)
        #expect(result.reason == ShepherdAdmission.CancellationReason.cancelled.rawValue)
        #expect(result.pasteAdmitted && !result.submitAdmitted)
        #expect(host.pasteCalls == 1 && host.submitCalls == 0)
        #expect(host.released == [intent.requestID])
        #expect(try await controller.continueInput(intent) == result)
        #expect(host.pasteCalls == 1)
    }

    @Test
    func cancellationBeforeInputDoesNotCreateAReceiptOrCallTheHost() async throws {
        let (controller, host, _) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        let operation = Task { try await controller.continueInput(intent) }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("A pre-cancelled request must not run.")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
        #expect(controller.receipt(requestID: intent.requestID) == nil)
    }

    @Test
    func waitFailureIsAnExplicitHeldOutcome() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        clock.action = { _ in throw WaitFailure.failed }
        let result = try await controller.continueInput(intent)
        #expect(result.state == .unknown)
        #expect(result.reason == ShepherdAdmission.CancellationReason.waitFailed.rawValue)
        #expect(result.pasteAdmitted && !result.submitAdmitted)
        #expect(host.submitCalls == 0 && host.released == [intent.requestID])
    }

    @Test(arguments: [0.01, 2.0, Double.nan])
    func earlyLateOrInvalidClockCannotSubmit(advance: TimeInterval) async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        clock.action = { _ in clock.now += advance }
        let result = try await controller.continueInput(intent)
        #expect(result.state == .unknown)
        #expect(result.pasteAdmitted && !result.submitAdmitted)
        #expect(host.submitCalls == 0 && host.released == [intent.requestID])
    }

    @Test
    func duplicateWhileWaitingDoesNotStartAnotherWriteOrDelay() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        clock.action = { seconds in
            let pending = try await controller.continueInput(intent)
            #expect(pending.state == .unknown && pending.pasteAdmitted && !pending.submitAdmitted)
            #expect(clock.waits == [0.15])
            clock.now += seconds
        }
        let result = try await controller.continueInput(intent)
        #expect(result.state == .accepted)
        host.current = nil
        #expect(try await controller.continueInput(intent) == result)
        #expect(host.pasteCalls == 1 && host.submitCalls == 1)
        #expect(clock.waits == [0.15])
    }

    @Test
    func conflictingReplayDoesNotReplaceTheStoredReceipt() async throws {
        let (controller, host, _) = setup()
        let observed = try token(controller, host)
        let intent = request(observed.id)
        let first = try await controller.continueInput(intent)
        let changed = ShepherdContinuationRequest(requestID: intent.requestID, tokenID: intent.tokenID, text: "Other work.")
        let conflict = try await controller.continueInput(changed)
        #expect(conflict.state == .unknown && conflict.reason == "request_conflict")
        #expect(controller.receipt(requestID: intent.requestID) == first)
        #expect(host.pasteCalls == 1 && host.submitCalls == 1)
    }

    @Test
    func invalidTextAndUnknownTokensAreExplicitErrorsWithoutInput() async throws {
        let (controller, host, _) = setup()
        await #expect(throws: ShepherdAdmissionController.Error.invalidRequest) {
            try await controller.continueInput(request(UUID(), text: " "))
        }
        await #expect(throws: ShepherdAdmissionController.Error.unknownToken) {
            try await controller.continueInput(request(UUID()))
        }
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
    }

    @Test
    func transportRefusalsAreNotPromotedToAccepted() async throws {
        let (controller, host, clock) = setup()
        let observed = try token(controller, host)
        host.admitsPaste = false
        let rejected = try await controller.continueInput(request(observed.id))
        #expect(rejected.state == .notSent && !rejected.pasteAdmitted)
        #expect(clock.waits.isEmpty && host.released.isEmpty)

        host.admitsPaste = true
        let next = try token(controller, host)
        host.admitsSubmit = false
        let intent = request(next.id)
        let partial = try await controller.continueInput(intent)
        #expect(partial.state == .unknown && partial.pasteAdmitted && !partial.submitAdmitted)
        #expect(host.released == [intent.requestID])
    }
}
