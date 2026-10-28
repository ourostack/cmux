public import Foundation

public enum ShepherdManagedInputOrigin: Equatable, Sendable {
    case owner
    case supervisor
}

public enum ShepherdManagedActivityKind: Equatable, Sendable {
    case callback
    case inspection
    case work
}

public enum ShepherdManagedHoldReason: Equatable, Sendable {
    case noInput
    case inputUnacknowledged
    case rootInFlight
    case rootFailed
    case activitiesInFlight
    case workCoverageUnavailable
    case backgroundWork
    case scheduledWakeups
    case ownerInputRequired
    case inputMismatch
    case conflictingActivity
    case unmatchedActivity
    case retentionLimit
    case invalidIdentifier
}

/// Work evidence only; this type cannot qualify a profile or admit any input.
/// Replay IDs survive for a backend generation; exhaustion requires explicit renewal.
public struct ShepherdManagedSessionState: Sendable {
    public static let maximumRetainedActivityIDs = 16_384
    public static let maximumRetainedInputIDs = 4_096
    public static let maximumObservedWorkIDs = 256
    public let identity: ShepherdManagedSessionIdentity
    public private(set) var currentInputID: UUID?
    public private(set) var currentInputOrigin: ShepherdManagedInputOrigin?
    public private(set) var activityRevision = UUID()
    public private(set) var eventRevision = UUID()
    private var providerInputID: String?
    private var rootFinished = false
    private var rootSucceeded = false
    private var ownerInputRequired = false
    private var fatalReason: ShepherdManagedHoldReason?
    private var retentionLimitReached = false
    private var activities: [String: ShepherdManagedActivityKind] = [:]
    private var retainedActivityIDs: Set<String> = []
    private var retainedInputIDs: Set<UUID> = []
    // Each bounded host input owns at most one immutable provider input ID.
    private var providerInputOwners: [String: UUID] = [:]
    private var workObservation: WorkObservation?

    public var outstandingActivityCount: Int { activities.count }
    public var hasCompleteWorkEvidence: Bool { holdReason == nil }
    public var requiresGenerationRenewal: Bool { retentionLimitReached && fatalReason == nil }
    public var holdReason: ShepherdManagedHoldReason? {
        if let fatalReason { return fatalReason }
        if retentionLimitReached { return .retentionLimit }
        guard let currentInputID else { return .noInput }
        if ownerInputRequired { return .ownerInputRequired }
        guard let providerInputID else { return .inputUnacknowledged }
        guard rootFinished else { return .rootInFlight }
        guard rootSucceeded else { return .rootFailed }
        guard activities.isEmpty else { return .activitiesInFlight }
        guard let observation = workObservation,
              observation.inputID == currentInputID,
              observation.providerInputID == providerInputID,
              observation.activityRevision == activityRevision else {
            return .workCoverageUnavailable
        }
        if observation.hasBackgroundJobs { return .backgroundWork }
        if observation.hasScheduledWakeups { return .scheduledWakeups }
        return nil
    }

    public init(identity: ShepherdManagedSessionIdentity) {
        self.identity = identity
    }

    public mutating func beginInput(_ input: UUID, origin: ShepherdManagedInputOrigin) -> Bool {
        eventRevision = UUID()
        guard fatalReason == nil, !retentionLimitReached else { return false }
        guard origin != .supervisor || hasCompleteWorkEvidence else { return false }
        guard activities.isEmpty, currentInputID == nil || rootFinished else { return false }
        guard !retainedInputIDs.contains(input) else { return reject(.inputMismatch) }
        guard retainedInputIDs.count < Self.maximumRetainedInputIDs else {
            return requireGenerationRenewal()
        }
        retainedInputIDs.insert(input)
        currentInputID = input
        currentInputOrigin = origin
        providerInputID = nil
        ownerInputRequired = false
        invalidateWork()
        return true
    }

    public mutating func acknowledgeInput(_ input: UUID, providerInputID: String) -> Bool {
        eventRevision = UUID()
        guard fatalReason == nil else { return false }
        guard currentInputID == input,
              ShepherdManagedSessionIdentity.validIdentifier(providerInputID),
              self.providerInputID == nil || self.providerInputID == providerInputID,
              providerInputOwners[providerInputID] == nil
                || providerInputOwners[providerInputID] == input else {
            return reject(.inputMismatch)
        }
        self.providerInputID = providerInputID
        providerInputOwners[providerInputID] = input
        return true
    }

    public func inputID(matchingProviderInputID providerInputID: String) -> UUID? {
        providerInputOwners[providerInputID]
    }

    public mutating func completeRoot(
        _ input: UUID, providerInputID: String, succeeded: Bool
    ) -> Bool {
        eventRevision = UUID()
        guard matchesInput(input, providerInputID: providerInputID) else { return false }
        guard !rootFinished || rootSucceeded == succeeded else { return reject(.inputMismatch) }
        rootFinished = true
        rootSucceeded = succeeded
        return true
    }

    public mutating func beginActivity(_ id: String, kind: ShepherdManagedActivityKind) -> Bool {
        eventRevision = UUID()
        guard fatalReason == nil, !retentionLimitReached else { return false }
        guard ShepherdManagedSessionIdentity.validIdentifier(id) else {
            return reject(.invalidIdentifier)
        }
        guard !retainedActivityIDs.contains(id) else { return reject(.conflictingActivity) }
        guard retainedActivityIDs.count < Self.maximumRetainedActivityIDs else {
            return requireGenerationRenewal()
        }
        retainedActivityIDs.insert(id)
        activities[id] = kind
        if kind == .work { invalidateWork() }
        return true
    }

    public mutating func finishActivity(_ id: String) -> Bool {
        eventRevision = UUID()
        guard let kind = activities.removeValue(forKey: id) else {
            return reject(.unmatchedActivity)
        }
        if kind == .work { invalidateWork() }
        return true
    }

    /// Only a native adapter with validated profile and complete inventories can assert coverage.
    public mutating func recordWorkSnapshot(
        _ input: UUID, providerInputID: String, activityRevision: UUID,
        backgroundJobs: [String]?, scheduledWakeups: [String]?, coverageComplete: Bool
    ) -> Bool {
        eventRevision = UUID()
        guard matchesInput(input, providerInputID: providerInputID) else { return false }
        workObservation = nil
        guard activityRevision == self.activityRevision, coverageComplete,
              let backgroundJobs, let scheduledWakeups,
              validInventory(backgroundJobs), validInventory(scheduledWakeups) else {
            return false
        }
        workObservation = WorkObservation(
            inputID: input, providerInputID: providerInputID, activityRevision: activityRevision,
            hasBackgroundJobs: !backgroundJobs.isEmpty,
            hasScheduledWakeups: !scheduledWakeups.isEmpty
        )
        return true
    }

    public mutating func requireOwnerInput() {
        eventRevision = UUID()
        ownerInputRequired = true
    }

    /// Later activity requires a fresh terminal event, never replay of a cached completion.
    public mutating func observeProviderActivity() {
        eventRevision = UUID()
        invalidateWork()
    }

    private mutating func invalidateWork() {
        activityRevision = UUID()
        workObservation = nil
        rootFinished = false
        rootSucceeded = false
    }

    private mutating func matchesInput(_ input: UUID, providerInputID: String) -> Bool {
        guard fatalReason == nil else { return false }
        guard currentInputID == input, self.providerInputID == providerInputID,
              ShepherdManagedSessionIdentity.validIdentifier(providerInputID) else {
            return reject(.inputMismatch)
        }
        return true
    }

    private mutating func reject(_ reason: ShepherdManagedHoldReason) -> Bool {
        if fatalReason == nil { fatalReason = reason }
        return false
    }

    private mutating func requireGenerationRenewal() -> Bool {
        retentionLimitReached = true
        return false
    }

    private func validInventory(_ identifiers: [String]) -> Bool {
        identifiers.count <= Self.maximumObservedWorkIDs
            && identifiers.allSatisfy(ShepherdManagedSessionIdentity.validIdentifier)
    }

    private struct WorkObservation: Sendable {
        let inputID: UUID
        let providerInputID: String
        let activityRevision: UUID
        let hasBackgroundJobs: Bool
        let hasScheduledWakeups: Bool
    }
}
