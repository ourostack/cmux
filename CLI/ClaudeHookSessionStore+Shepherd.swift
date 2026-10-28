import CmuxControlSocket
import CmuxFoundation
import Foundation

extension ClaudeHookSessionRecord {
    mutating func retireShepherdProducerIfOwnershipChanged() {
        guard let launch = shepherdProducer?.launch else { return }
        guard UUID(uuidString: workspaceId) == launch.workspaceID,
              UUID(uuidString: surfaceId) == launch.surfaceID,
              pid == Int(launch.pid), pidStartSeconds == launch.pidStartSeconds,
              pidStartMicroseconds == launch.pidStartMicroseconds else {
            shepherdProducer = nil
            return
        }
    }

    mutating func invalidateShepherdReadiness() {
        shepherdReadiness = nil
        shepherdWorkRevision = UUID()
    }
}

extension ClaudeHookSessionStore {
    func invalidateShepherdReadiness(sessionId: String) throws {
        try withLockedState { state in
            guard var record = state.sessions[sessionId] else { return }
            record.invalidateShepherdReadiness()
            state.sessions[sessionId] = record
        }
    }

    /// The root process birth encloses native inspection and the locked commit.
    @discardableResult
    func recordShepherdReadiness(
        sessionID: String, workspaceID: UUID, surfaceID: UUID, stopInput: [String: Any],
        inspection: () throws -> [String: Any],
        processIdentity: (Int32) -> AgentPIDProcessIdentity?
    ) throws -> Bool {
        guard let tasks = stopInput["background_tasks"] as? [Any], tasks.isEmpty,
              let crons = stopInput["session_crons"] as? [Any], crons.isEmpty,
              let record = try lookup(sessionId: sessionID),
              let revision = record.shepherdWorkRevision,
              let rootPID = record.pid.flatMap(Int32.init(exactly:)),
              let birth = processIdentity(rootPID),
              birth.startSeconds == record.pidStartSeconds,
              birth.startMicroseconds == record.pidStartMicroseconds,
              let scope = try ShepherdHookReadinessScope.capture(
                  inspection: JSONSerialization.data(withJSONObject: inspection()),
                  workspaceID: workspaceID, surfaceID: surfaceID, pid: rootPID,
                  pidStartSeconds: birth.startSeconds, pidStartMicroseconds: birth.startMicroseconds
              ),
              let proof = ShepherdHookReadinessProof(stopInput: stopInput, sessionID: sessionID, scope: scope),
              processIdentity(rootPID) == birth else { return false }
        return try commitShepherdReadiness(proof, expectedWorkRevision: revision) {
            processIdentity(rootPID)
        }
    }

    /// Compare-and-set under the existing store lock. A late Stop cannot undo newer work.
    @discardableResult
    func commitShepherdReadiness(
        _ proof: ShepherdHookReadinessProof, expectedWorkRevision: UUID,
        processIdentity: () -> AgentPIDProcessIdentity?
    ) throws -> Bool {
        try withLockedState { state in
            let scope = proof.scope
            let birth = AgentPIDProcessIdentity(
                pid: scope.pid, startSeconds: scope.pidStartSeconds,
                startMicroseconds: scope.pidStartMicroseconds
            )
            guard processIdentity() == birth else { return false }
            guard proof.version == 1, state.decodeDiagnostics.droppedCount == 0,
                  var record = state.sessions[proof.sessionID],
                  record.sessionId == proof.sessionID,
                  record.shepherdWorkRevision == expectedWorkRevision,
                  UUID(uuidString: record.workspaceId) == scope.workspaceID,
                  UUID(uuidString: record.surfaceId) == scope.surfaceID,
                  state.activeSessionsBySurface.filter({
                      UUID(uuidString: $0.key) == scope.surfaceID
                  }).map(\.value.sessionId) == [proof.sessionID],
                  record.pid == Int(scope.pid),
                  record.pidStartSeconds == scope.pidStartSeconds,
                  record.pidStartMicroseconds == scope.pidStartMicroseconds,
                  record.turnSettled == true, record.hookEventName == "Stop",
                  record.activePromptDepth == nil || record.activePromptDepth == 0,
                  processIdentity() == birth else { return false }
            record.activePromptDepth = 0
            record.shepherdReadiness = proof
            state.sessions[proof.sessionID] = record
            return true
        }
    }
}
