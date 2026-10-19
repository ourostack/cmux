public import Foundation

/// Synchronous hook authority, deliberately independent of queued lifecycle metadata.
public struct ShepherdHookProducerState: Codable, Equatable, Sendable {
    public let launch: ShepherdHookLaunchReceipt
    public let sessionID: String
    public private(set) var promptID: UUID?
    public private(set) var promptScope: ShepherdHookReadinessScope?
    public private(set) var workRevision: UUID
    public private(set) var proof: ShepherdHookProducerProof?

    public init?(
        sessionID: String, launch: ShepherdHookLaunchReceipt,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) {
        guard !sessionID.isEmpty, launch.isQualified(using: qualifiedBinaries) else { return nil }
        self.launch = launch
        self.sessionID = sessionID
        workRevision = UUID()
    }

    @discardableResult
    public mutating func invalidate(promptID: UUID?) -> UUID {
        if self.promptID != promptID { promptScope = nil }
        self.promptID = promptID
        workRevision = UUID()
        proof = nil
        return workRevision
    }

    /// Pins an observed epoch; this is not proof that its input caused the prompt.
    @discardableResult
    public mutating func capturePromptScope(
        _ scope: ShepherdHookReadinessScope, promptID: UUID, expectedWorkRevision: UUID
    ) -> Bool {
        guard self.promptID == promptID, workRevision == expectedWorkRevision,
              matchesLaunch(scope), promptScope == nil || promptScope == scope else { return false }
        promptScope = scope
        return true
    }

    @discardableResult
    public mutating func seal(
        stopInput: [String: Any], scope: ShepherdHookReadinessScope,
        expectedWorkRevision: UUID
    ) -> Bool {
        guard workRevision == expectedWorkRevision else { return false }
        proof = nil
        guard let promptID, let rawPrompt = stopInput["prompt_id"] as? String,
              UUID(uuidString: rawPrompt) == promptID,
              promptScope == scope,
              stopInput["session_id"] as? String == sessionID,
              stopInput["hook_event_name"] as? String == "Stop",
              let tasks = stopInput["background_tasks"] as? [Any], tasks.isEmpty,
              let crons = stopInput["session_crons"] as? [Any], crons.isEmpty,
              matchesLaunch(scope) else { return false }
        proof = ShepherdHookProducerProof(
            sessionID: sessionID, launchReceiptID: launch.id, promptID: promptID,
            workRevision: workRevision, scope: scope
        )
        return true
    }

    public func proof(
        matching scope: ShepherdHookReadinessScope,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) -> ShepherdHookProducerProof? {
        guard !sessionID.isEmpty, launch.isQualified(using: qualifiedBinaries), matchesLaunch(scope),
              let promptID, let proof, proof.version == 2,
              promptScope == scope,
              proof.launchReceiptID == launch.id, proof.sessionID == sessionID,
              proof.promptID == promptID, proof.workRevision == workRevision,
              proof.scope == scope else { return nil }
        return proof
    }

    public static func readStore(
        _ data: Data, matching scope: ShepherdHookReadinessScope,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) throws -> Self? {
        guard let state = try currentProducer(
            data, workspaceID: scope.workspaceID, surfaceID: scope.surfaceID
        ), state.proof(matching: scope, qualifiedBinaries: qualifiedBinaries) != nil else { return nil }
        return state
    }

    public static func readRegisteredLaunch(
        _ data: Data, hostInstance: UUID, workspaceID: UUID, surfaceID: UUID,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) throws -> ShepherdHookLaunchReceipt? {
        guard let state = try currentProducer(data, workspaceID: workspaceID, surfaceID: surfaceID),
              state.launch.hostInstance == hostInstance,
              state.launch.isQualified(using: qualifiedBinaries) else { return nil }
        return state.launch
    }

    private static func currentProducer(
        _ data: Data, workspaceID: UUID, surfaceID: UUID
    ) throws -> Self? {
        guard data.count <= 8 * 1024 * 1024 else { return nil }
        let store = try JSONDecoder().decode(Store.self, from: data)
        let candidates = store.sessions.filter {
            UUID(uuidString: $0.value.surfaceId) == surfaceID
                && $0.value.shepherdProducer != nil
        }
        let active = store.activeSessionsBySurface.filter {
            UUID(uuidString: $0.key) == surfaceID
        }
        guard store.version == 1, candidates.count == 1, active.count == 1,
              let candidate = candidates.first, let owner = active.first,
              candidate.key == candidate.value.sessionId, owner.value.sessionId == candidate.key,
              UUID(uuidString: candidate.value.workspaceId) == workspaceID,
              let state = candidate.value.shepherdProducer, state.sessionID == candidate.key,
              !state.sessionID.isEmpty,
              state.launch.workspaceID == workspaceID, state.launch.surfaceID == surfaceID,
              candidate.value.pid == state.launch.pid,
              candidate.value.pidStartSeconds == state.launch.pidStartSeconds,
              candidate.value.pidStartMicroseconds == state.launch.pidStartMicroseconds else {
            return nil
        }
        return state
    }

    private func matchesLaunch(_ scope: ShepherdHookReadinessScope) -> Bool {
        let prefix = "\(launch.pid):"
        return scope.hostInstance == launch.hostInstance
            && scope.workspaceID == launch.workspaceID && scope.surfaceID == launch.surfaceID
            && scope.pid == launch.pid && scope.pidStartSeconds == launch.pidStartSeconds
            && scope.pidStartMicroseconds == launch.pidStartMicroseconds
            && scope.surfaceGeneration > 0 && scope.processInstance.hasPrefix(prefix)
            && UInt64(scope.processInstance.dropFirst(prefix.count)).map { $0 > 0 } == true
    }

    private struct Store: Decodable {
        let version: Int
        let sessions: [String: Record]
        let activeSessionsBySurface: [String: Active]
    }

    private struct Active: Decodable {
        let sessionId: String
    }

    private struct Record: Decodable {
        let sessionId: String
        let workspaceId: String
        let surfaceId: String
        let pid: Int32?
        let pidStartSeconds: Int64?
        let pidStartMicroseconds: Int64?
        let hookEventName: String?
        let turnSettled: Bool?
        let activePromptDepth: Int?
        let shepherdReadiness: ShepherdHookReadinessProof?
        let shepherdProducer: ShepherdHookProducerState?
    }
}
