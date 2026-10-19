import CmuxControlSocket
import CmuxFoundation
import Foundation

extension ClaudeHookSessionStore {
    func lookupShepherdLaunch(
        id: UUID, deadline: Date = Date().addingTimeInterval(1)
    ) throws -> ShepherdHookLaunchReceipt? {
        try readShepherdLaunch(deadline: deadline) { $0.id == id }
    }

    func lookupShepherdLaunch(
        root: AgentPIDProcessIdentity, deadline: Date = Date().addingTimeInterval(1)
    ) throws -> ShepherdHookLaunchReceipt? {
        try readShepherdLaunch(deadline: deadline) { Self.shepherdBirth($0) == root }
    }

    func retireShepherdLaunches(
        surfaceID: UUID, deadline: Date = Date().addingTimeInterval(1)
    ) throws {
        try withLockedState(deadline: deadline) { state in
            guard state.decodeDiagnostics.droppedCount == 0 else {
                throw CLIError(message: "Shepherd eligibility could not be retired from an intact session store.")
            }
            Self.retireShepherdProducers(&state, surfaceID: surfaceID)
        }
    }

    func installShepherdLaunch(
        _ launch: ShepherdHookLaunchReceipt,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries,
        processIdentity: (Int32) -> AgentPIDProcessIdentity?,
        deadline: Date = Date().addingTimeInterval(1)
    ) throws {
        try withLockedState(deadline: deadline) { state in
            let birth = Self.shepherdBirth(launch)
            guard state.decodeDiagnostics.droppedCount == 0,
                  launch.isQualified(using: qualifiedBinaries),
                  processIdentity(launch.pid) == birth else {
                throw CLIError(message: "Shepherd launch registration could not establish its exact qualified root.")
            }
            let existing = state.sessions.filter {
                guard let prior = $0.value.shepherdProducer?.launch else { return false }
                return Self.shepherdBirth(prior) == birth
            }
            if let prior = existing.first {
                guard existing.count == 1, prior.value.shepherdProducer?.launch == launch,
                      var record = state.sessions[prior.key], var producer = record.shepherdProducer else {
                    throw CLIError(message: "Shepherd launch re-entry must retain its identical validated settings and receipt.")
                }
                producer.invalidate(promptID: nil)
                record.shepherdProducer = producer
                state.sessions[prior.key] = record
            } else {
                Self.retireShepherdProducers(&state, surfaceID: launch.surfaceID)
                let pendingID = "__shepherd_launch__\(launch.id.uuidString)"
                var record = makeSessionRecord(
                    state: state, sessionId: pendingID, workspaceId: launch.workspaceID.uuidString,
                    surfaceId: launch.surfaceID.uuidString, now: Date().timeIntervalSince1970
                )
                record.pid = Int(launch.pid)
                record.pidStartSeconds = launch.pidStartSeconds
                record.pidStartMicroseconds = launch.pidStartMicroseconds
                guard let producer = ShepherdHookProducerState(
                    sessionID: pendingID, launch: launch, qualifiedBinaries: qualifiedBinaries
                ) else {
                    throw CLIError(message: "Shepherd launch registration did not produce an eligible state.")
                }
                record.shepherdProducer = producer
                state.sessions[pendingID] = record
            }
            guard processIdentity(launch.pid) == birth else {
                throw CLIError(message: "Shepherd launch root changed during registration.")
            }
        }
    }

    /// This write completes before the hook can enqueue telemetry or let the agent advance.
    func beginShepherdProducerEvent(
        launchID: UUID, sessionID: String, event: String, promptID: UUID?,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries,
        processIdentity: (Int32) -> AgentPIDProcessIdentity?,
        deadline: Date = Date().addingTimeInterval(1)
    ) throws -> UUID {
        try withLockedState(deadline: deadline) { state in
            let matches = state.sessions.filter { $0.value.shepherdProducer?.launch.id == launchID }
            guard state.decodeDiagnostics.droppedCount == 0, !sessionID.isEmpty,
                  matches.count == 1, let match = matches.first,
                  var producer = match.value.shepherdProducer,
                  producer.launch.isQualified(using: qualifiedBinaries) else {
                throw CLIError(message: "Shepherd hook has no unique qualified launch registration.")
            }
            let launch = producer.launch
            let pendingID = "__shepherd_launch__\(launch.id.uuidString)"
            let birth = Self.shepherdBirth(launch)
            guard processIdentity(launch.pid) == birth else {
                throw CLIError(message: "Shepherd hook root no longer matches its launch registration.")
            }
            if producer.sessionID != sessionID {
                guard match.key == pendingID || event == "UserPromptSubmit",
                      let rebound = ShepherdHookProducerState(
                          sessionID: sessionID, launch: launch, qualifiedBinaries: qualifiedBinaries
                      ) else {
                    throw CLIError(message: "A late Shepherd lifecycle event cannot rebind the current session.")
                }
                producer = rebound
            }
            let currentPrompt: UUID?
            switch event {
            case "UserPromptSubmit": currentPrompt = promptID
            case "PreToolUse", "Stop":
                currentPrompt = producer.promptID == promptID ? producer.promptID : nil
            default: currentPrompt = nil
            }
            let revision = producer.invalidate(promptID: currentPrompt)
            Self.retireShepherdProducers(&state, surfaceID: launch.surfaceID)
            if match.key == pendingID {
                state.sessions.removeValue(forKey: match.key)
            }
            let now = Date().timeIntervalSince1970
            var record = makeSessionRecord(
                state: state, sessionId: sessionID, workspaceId: launch.workspaceID.uuidString,
                surfaceId: launch.surfaceID.uuidString, now: now
            )
            record.workspaceId = launch.workspaceID.uuidString
            record.surfaceId = launch.surfaceID.uuidString
            record.pid = Int(launch.pid)
            record.pidStartSeconds = launch.pidStartSeconds
            record.pidStartMicroseconds = launch.pidStartMicroseconds
            record.shepherdProducer = event == "SessionEnd" ? nil : producer
            record.updatedAt = now
            state.sessions[sessionID] = record
            state.activeSessionsBySurface[launch.surfaceID.uuidString] = ClaudeHookActiveSessionRecord(
                sessionId: sessionID, updatedAt: now
            )
            guard processIdentity(launch.pid) == birth else {
                throw CLIError(message: "Shepherd hook root changed before its invalidation committed.")
            }
            return revision
        }
    }

    @discardableResult
    func commitShepherdProducerReadiness(
        launchID: UUID, sessionID: String, expectedWorkRevision: UUID,
        stopInput: [String: Any], scope: ShepherdHookReadinessScope,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries,
        processIdentity: (Int32) -> AgentPIDProcessIdentity?,
        deadline: Date = Date().addingTimeInterval(1)
    ) throws -> Bool {
        try updateShepherdObservation(
            launchID: launchID, sessionID: sessionID, expectedWorkRevision: expectedWorkRevision,
            scope: scope, qualifiedBinaries: qualifiedBinaries,
            processIdentity: processIdentity, deadline: deadline
        ) {
            $0.seal(stopInput: stopInput, scope: scope, expectedWorkRevision: expectedWorkRevision)
        }
    }

    @discardableResult
    func captureShepherdPromptScope(
        launchID: UUID, sessionID: String, promptID: UUID, expectedWorkRevision: UUID,
        scope: ShepherdHookReadinessScope,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries,
        processIdentity: (Int32) -> AgentPIDProcessIdentity?,
        deadline: Date = Date().addingTimeInterval(1)
    ) throws -> Bool {
        try updateShepherdObservation(
            launchID: launchID, sessionID: sessionID, expectedWorkRevision: expectedWorkRevision,
            scope: scope, qualifiedBinaries: qualifiedBinaries,
            processIdentity: processIdentity, deadline: deadline
        ) {
            $0.capturePromptScope(scope, promptID: promptID, expectedWorkRevision: expectedWorkRevision)
        }
    }

    private func updateShepherdObservation(
        launchID: UUID, sessionID: String, expectedWorkRevision: UUID,
        scope: ShepherdHookReadinessScope, qualifiedBinaries: [String: Set<String>],
        processIdentity: (Int32) -> AgentPIDProcessIdentity?, deadline: Date,
        update: (inout ShepherdHookProducerState) -> Bool
    ) throws -> Bool {
        try withLockedState(deadline: deadline) { state in
            guard state.decodeDiagnostics.droppedCount == 0,
                  var record = state.sessions[sessionID], var producer = record.shepherdProducer,
                  record.sessionId == sessionID, producer.sessionID == sessionID,
                  producer.launch.id == launchID, producer.workRevision == expectedWorkRevision,
                  producer.launch.isQualified(using: qualifiedBinaries),
                  UUID(uuidString: record.workspaceId) == scope.workspaceID,
                  UUID(uuidString: record.surfaceId) == scope.surfaceID,
                  record.pid == Int(scope.pid), record.pidStartSeconds == scope.pidStartSeconds,
                  record.pidStartMicroseconds == scope.pidStartMicroseconds,
                  state.activeSessionsBySurface.filter({
                      UUID(uuidString: $0.key) == scope.surfaceID
                  }).map(\.value.sessionId) == [sessionID] else { return false }
            let birth = Self.shepherdBirth(producer.launch)
            guard processIdentity(scope.pid) == birth else { return false }
            let updated = update(&producer)
            guard processIdentity(scope.pid) == birth else { return false }
            record.shepherdProducer = producer
            state.sessions[sessionID] = record
            return updated
        }
    }

    private static func shepherdBirth(_ launch: ShepherdHookLaunchReceipt) -> AgentPIDProcessIdentity {
        AgentPIDProcessIdentity(
            pid: launch.pid, startSeconds: launch.pidStartSeconds,
            startMicroseconds: launch.pidStartMicroseconds
        )
    }

    private func readShepherdLaunch(
        deadline: Date, matches: (ShepherdHookLaunchReceipt) -> Bool
    ) throws -> ShepherdHookLaunchReceipt? {
        try withLockedState(deadline: deadline, persist: false) { state in
            let candidates = state.sessions.values.compactMap { $0.shepherdProducer?.launch }.filter(matches)
            guard state.decodeDiagnostics.droppedCount == 0, candidates.count <= 1 else {
                throw CLIError(message: "Shepherd launch lookup could not establish one intact registration.")
            }
            return candidates.first
        }
    }

    private static func retireShepherdProducers(
        _ state: inout ClaudeHookSessionStoreFile, surfaceID: UUID
    ) {
        for key in Array(state.sessions.keys) {
            guard var record = state.sessions[key], UUID(uuidString: record.surfaceId) == surfaceID else {
                continue
            }
            record.shepherdProducer = nil
            record.invalidateShepherdReadiness()
            state.sessions[key] = record
        }
    }
}
