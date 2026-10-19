import CmuxControlSocket
import Foundation
import Testing

@Suite struct ShepherdManagedSessionStateTests {
    @Test func anEmptyLocalLedgerIsNotPositiveIdleEvidence() throws {
        let state = ShepherdManagedSessionState(identity: try managedIdentity())
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .noInput)
    }

    @Test func onlyTheCurrentAcknowledgedSuccessfulRootAndCompleteCoverageCanSettle() throws {
        var state = ShepherdManagedSessionState(identity: try managedIdentity())
        let input = UUID()
        expectManaged(state.beginInput(input, origin: .owner))
        #expect(!state.hasCompleteWorkEvidence)
        expectManaged(state.acknowledgeInput(input, providerInputID: "server-a"))
        #expect(!state.hasCompleteWorkEvidence)
        expectManaged(state.completeRoot(input, providerInputID: "server-a", succeeded: true))
        #expect(!state.hasCompleteWorkEvidence)
        expectManaged(state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: state.activityRevision,
            backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
        ))
        #expect(state.hasCompleteWorkEvidence)
        #expect(state.holdReason == nil)
    }

    @Test(arguments: ["ack", "result", "jobs", "wakeups", "coverage", "failure"])
    func everyMissingOrNegativeFactWithholdsInput(fact: String) throws {
        var state = ShepherdManagedSessionState(identity: try managedIdentity())
        let input = UUID()
        expectManaged(state.beginInput(input, origin: .owner))
        if fact != "ack" {
            expectManaged(state.acknowledgeInput(input, providerInputID: "server-a"))
        }
        if fact != "result" {
            _ = state.completeRoot(input, providerInputID: "server-a", succeeded: fact != "failure")
        }
        _ = state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: state.activityRevision,
            backgroundJobs: fact == "jobs" ? nil : [],
            scheduledWakeups: fact == "wakeups" ? nil : [],
            coverageComplete: fact != "coverage"
        )
        #expect(!state.hasCompleteWorkEvidence)
    }

    @Test(arguments: [ShepherdManagedActivityKind.callback, .inspection, .work])
    func outstandingOwnedActivitiesArePositiveBarriers(kind: ShepherdManagedActivityKind) throws {
        var state = try settledManagedState()
        expectManaged(state.beginActivity("owned-a", kind: kind))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.outstandingActivityCount == 1)
    }

    @Test func aStopCanSettleBeforeItsOwnResponseWithoutLosingItsProof() throws {
        var state = ShepherdManagedSessionState(identity: try managedIdentity())
        let input = UUID()
        expectManaged(state.beginInput(input, origin: .owner))
        expectManaged(state.acknowledgeInput(input, providerInputID: "server-a"))
        expectManaged(state.beginActivity("stop-response", kind: .callback))
        expectManaged(state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: state.activityRevision,
            backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
        ))
        expectManaged(state.completeRoot(input, providerInputID: "server-a", succeeded: true))
        #expect(!state.hasCompleteWorkEvidence)
        expectManaged(state.finishActivity("stop-response"))
        #expect(state.hasCompleteWorkEvidence)
    }

    @Test func finishingAnInventoryDoesNotInventOrDiscardItsExactSnapshot() throws {
        var state = try settledManagedState()
        let input = try #require(state.currentInputID)
        let revision = state.activityRevision
        expectManaged(state.beginActivity("inventory", kind: .inspection))
        expectManaged(state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: revision,
            backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
        ))
        #expect(!state.hasCompleteWorkEvidence)
        expectManaged(state.finishActivity("inventory"))
        #expect(state.hasCompleteWorkEvidence)
    }

    @Test func realWorkInvalidatesAnOlderEmptySnapshot() throws {
        var state = try settledManagedState()
        let oldRevision = state.activityRevision
        expectManaged(state.beginActivity("command", kind: .work))
        #expect(state.activityRevision != oldRevision)
        expectManaged(state.finishActivity("command"))
        #expect(!state.hasCompleteWorkEvidence)
        let input = try #require(state.currentInputID)
        expectManaged(!state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: oldRevision,
            backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
        ))
        #expect(!state.hasCompleteWorkEvidence)
    }

    @Test func aDuplicateActivityCannotOverwriteAnExistingCallback() throws {
        var state = try settledManagedState()
        expectManaged(state.beginActivity("call-a", kind: .work))
        expectManaged(!state.beginActivity("call-a", kind: .callback))
        #expect(state.outstandingActivityCount == 1)
        expectManaged(state.finishActivity("call-a"))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .conflictingActivity)
        #expect(!state.requiresGenerationRenewal)
    }

    @Test func aMissingOrRepeatedCallbackCannotDecrementAnotherEntry() throws {
        var state = try settledManagedState()
        expectManaged(state.beginActivity("call-a", kind: .callback))
        expectManaged(!state.finishActivity("call-b"))
        #expect(state.outstandingActivityCount == 1)
        expectManaged(state.finishActivity("call-a"))
        expectManaged(!state.finishActivity("call-a"))
        #expect(state.outstandingActivityCount == 0)
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .unmatchedActivity)
    }

    @Test func aCompletedCallbackIDCannotBeReusedForDifferentWork() throws {
        var state = try settledManagedState()
        expectManaged(state.beginActivity("call-a", kind: .callback))
        expectManaged(state.finishActivity("call-a"))
        expectManaged(!state.beginActivity("call-a", kind: .work))
        #expect(!state.hasCompleteWorkEvidence)
    }

    @Test(arguments: ["ack", "complete", "snapshot"])
    func oldInputACannotSettleNewInputB(event: String) throws {
        var state = try settledManagedState()
        let old = try #require(state.currentInputID)
        let current = UUID()
        expectManaged(state.beginInput(current, origin: .owner))
        expectManaged(state.acknowledgeInput(current, providerInputID: "server-b"))
        switch event {
        case "ack":
            expectManaged(!state.acknowledgeInput(old, providerInputID: "server-a"))
        case "complete":
            expectManaged(!state.completeRoot(old, providerInputID: "server-a", succeeded: true))
        default:
            expectManaged(!state.recordWorkSnapshot(
                old, providerInputID: "server-a", activityRevision: state.activityRevision,
                backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
            ))
        }
        #expect(state.currentInputID == current)
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .inputMismatch)
    }

    @Test func conflictingProviderAcknowledgementsCannotRetargetAnInput() throws {
        var state = try settledManagedState()
        let input = try #require(state.currentInputID)
        expectManaged(state.acknowledgeInput(input, providerInputID: "server-a"))
        expectManaged(!state.acknowledgeInput(input, providerInputID: "server-b"))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .inputMismatch)
    }

    @Test func aProviderInputIDCannotBeReassignedToAnotherHostInput() throws {
        var state = try settledManagedState()
        let original = try #require(state.currentInputID)
        let newer = UUID()
        expectManaged(state.beginInput(newer, origin: .owner))
        expectManaged(!state.acknowledgeInput(newer, providerInputID: "server-a"))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .inputMismatch)
        #expect(state.inputID(matchingProviderInputID: "server-a") == original)
        #expect(state.inputID(matchingProviderInputID: "missing") == nil)
    }

    @Test func aHostInputIDCannotBeReusedAfterItsRootCompleted() throws {
        var state = try settledManagedState()
        let input = try #require(state.currentInputID)
        expectManaged(!state.beginInput(input, origin: .owner))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .inputMismatch)
    }

    @Test func unsolicitedProviderActivityInvalidatesBothCompletionAndCoverage() throws {
        var state = try settledManagedState()
        let before = state.activityRevision
        state.observeProviderActivity()
        #expect(state.activityRevision != before)
        #expect(!state.hasCompleteWorkEvidence)
    }

    @Test(arguments: ["pid", "birth", "microseconds", "session", "generation", "executable", "profile"])
    func unboundOrMalformedBackendIdentitiesAreRejected(field: String) {
        let identity = ShepherdManagedSessionIdentity(
            hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
            backendPID: field == "pid" ? 0 : 123,
            backendStartSeconds: field == "birth" ? 0 : 1_792_400_000,
            backendStartMicroseconds: field == "microseconds" ? 1_000_000 : 42,
            provider: .claude, providerSessionID: field == "session" ? "" : "session-a",
            surfaceGeneration: field == "generation" ? 0 : 1,
            executableSHA256: String(repeating: field == "executable" ? "A" : "a", count: 64),
            profileSHA256: String(repeating: "b", count: field == "profile" ? 63 : 64)
        )
        #expect(identity == nil)
    }

    @Test func humanQuestionsCannotBeClearedByAnotherAutomaticContinuation() throws {
        var state = try settledManagedState()
        state.requireOwnerInput()
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .ownerInputRequired)
        expectManaged(!state.beginInput(UUID(), origin: .supervisor))
        expectManaged(state.beginInput(UUID(), origin: .owner))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason != .ownerInputRequired)
    }

    @Test func anAutomaticInputCannotStartAnUnobservedOrBusyRoot() throws {
        var state = ShepherdManagedSessionState(identity: try managedIdentity())
        expectManaged(!state.beginInput(UUID(), origin: .supervisor))
        expectManaged(state.beginInput(UUID(), origin: .owner))
        expectManaged(!state.beginInput(UUID(), origin: .owner))
        expectManaged(!state.beginInput(UUID(), origin: .supervisor))
    }

    @Test(arguments: ["jobs", "wakeups"])
    func registeredBackgroundWorkOrWakeupsCannotBeCalledEmpty(kind: String) throws {
        var state = try settledManagedState()
        let input = try #require(state.currentInputID)
        _ = state.recordWorkSnapshot(
            input, providerInputID: "server-a", activityRevision: state.activityRevision,
            backgroundJobs: kind == "jobs" ? ["job-a"] : [],
            scheduledWakeups: kind == "wakeups" ? ["wakeup-a"] : [],
            coverageComplete: true
        )
        #expect(!state.hasCompleteWorkEvidence)
    }

    @Test func activityRetentionOverflowHoldsInsteadOfEvictingBarriers() throws {
        var state = try settledManagedState()
        for index in 0..<ShepherdManagedSessionState.maximumRetainedActivityIDs {
            expectManaged(state.beginActivity("callback-\(index)", kind: .callback))
            expectManaged(state.finishActivity("callback-\(index)"))
        }
        expectManaged(!state.beginActivity("overflow", kind: .callback))
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.holdReason == .retentionLimit)
        #expect(state.requiresGenerationRenewal)
    }

    @Test func ordinaryForegroundActivityDoesNotExhaustTheGenerationAfter256Callbacks() throws {
        var state = try settledManagedState()
        for index in 0..<1_024 {
            expectManaged(state.beginActivity("ordinary-\(index)", kind: .callback))
            expectManaged(state.finishActivity("ordinary-\(index)"))
        }
        #expect(state.hasCompleteWorkEvidence)
    }

    @Test func theInputRetentionCeilingAlsoRefusesWithoutDiscardingOldMappings() throws {
        var state = ShepherdManagedSessionState(identity: try managedIdentity())
        var first: UUID?
        for index in 0..<ShepherdManagedSessionState.maximumRetainedInputIDs {
            let input = UUID()
            if first == nil { first = input }
            expectManaged(state.beginInput(input, origin: .owner))
            expectManaged(state.acknowledgeInput(input, providerInputID: "provider-\(index)"))
            expectManaged(state.completeRoot(input, providerInputID: "provider-\(index)", succeeded: true))
        }
        expectManaged(!state.beginInput(UUID(), origin: .owner))
        #expect(state.holdReason == .retentionLimit)
        #expect(state.inputID(matchingProviderInputID: "provider-0") == first)
        #expect(!state.hasCompleteWorkEvidence)
        #expect(state.requiresGenerationRenewal)
    }

    @Test func activityChangesInvalidateTheEventRevisionEvenForBookkeeping() throws {
        var state = try settledManagedState()
        let original = state.eventRevision
        expectManaged(state.beginActivity("inspection", kind: .inspection))
        #expect(state.eventRevision != original)
        let inFlight = state.eventRevision
        expectManaged(state.finishActivity("inspection"))
        #expect(state.eventRevision != inFlight)
    }
}

private func managedIdentity() throws -> ShepherdManagedSessionIdentity {
    try #require(ShepherdManagedSessionIdentity(
        hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
        backendPID: 123, backendStartSeconds: 1_792_400_000,
        backendStartMicroseconds: 42, provider: .claude,
        providerSessionID: "session-a", surfaceGeneration: 1,
        executableSHA256: String(repeating: "a", count: 64),
        profileSHA256: String(repeating: "b", count: 64)
    ))
}

private func settledManagedState() throws -> ShepherdManagedSessionState {
    var state = ShepherdManagedSessionState(identity: try managedIdentity())
    let input = UUID()
    expectManaged(state.beginInput(input, origin: .owner))
    expectManaged(state.acknowledgeInput(input, providerInputID: "server-a"))
    expectManaged(state.completeRoot(input, providerInputID: "server-a", succeeded: true))
    expectManaged(state.recordWorkSnapshot(
        input, providerInputID: "server-a", activityRevision: state.activityRevision,
        backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
    ))
    return state
}

private func expectManaged(
    _ condition: Bool, fileID: String = #fileID, filePath: String = #filePath,
    line: Int = #line, column: Int = #column
) {
    #expect(condition, sourceLocation: SourceLocation(
        fileID: fileID, filePath: filePath, line: line, column: column
    ))
}
