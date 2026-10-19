import CmuxControlSocket
import Foundation
import Testing

@Suite struct ShepherdHookProducerStateTests {
    @Test func delayedStopCannotAcknowledgeInputNewerThanItsPromptObservation() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = state.invalidate(promptID: prompt)
        let captured = state.capturePromptScope(
            fixture.scope, promptID: prompt, expectedWorkRevision: revision
        )
        #expect(captured)
        var newer = fixture.scope
        newer.inputRevision += 1
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: newer, expectedWorkRevision: revision
        )
        #expect(!sealed)
        #expect(state.proof == nil)
    }

    @Test func aPromptWithNoNativeObservationCannotProduceReadiness() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = state.invalidate(promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(!sealed)
    }

    @Test func toolEpochsRetainButCannotReplaceTheSamePromptObservation() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        _ = fixture.startPrompt(&state, promptID: prompt)
        let revision = state.invalidate(promptID: prompt)
        #expect(state.promptScope == fixture.scope)
        var changed = fixture.scope
        changed.inputRevision += 1
        let replaced = state.capturePromptScope(
            changed, promptID: prompt, expectedWorkRevision: revision
        )
        #expect(!replaced)
        #expect(state.promptScope == fixture.scope)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        _ = state.invalidate(promptID: UUID())
        #expect(state.promptScope == nil)
    }

    @Test func launchCanBindTheNativeHostBeforeTheShellHasExecutedAnAgent() throws {
        let fixture = ProducerStateFixture()
        func data(protocolValue: Any = 1, workspace: UUID? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "protocol_version": protocolValue, "host_instance": fixture.host.uuidString,
                "snapshot": [
                    "workspace_id": (workspace ?? fixture.workspace).uuidString,
                    "surface_id": fixture.surface.uuidString, "surface_generation": 1,
                    "agent": NSNull(), "process_instance": NSNull(),
                ],
                "token": NSNull(),
            ])
        }
        #expect(try ShepherdHookLaunchReceipt.captureHost(
            inspection: data(), workspaceID: fixture.workspace, surfaceID: fixture.surface
        ) == fixture.host)
        #expect(try ShepherdHookLaunchReceipt.captureHost(
            inspection: data(workspace: UUID()), workspaceID: fixture.workspace, surfaceID: fixture.surface
        ) == nil)
        let invalid = try data(protocolValue: true)
        #expect(throws: DecodingError.self) {
            try ShepherdHookLaunchReceipt.captureHost(
                inspection: invalid, workspaceID: fixture.workspace, surfaceID: fixture.surface
            )
        }
    }

    @Test func launchBindingCanIdentifyTheRootBeforeReadinessWithoutInventingAProof() throws {
        let fixture = ProducerStateFixture()
        let state = try fixture.state()
        let bytes = try fixture.storeData(state: state, settled: false, event: "SessionStart", depth: 0)
        let launch = try ShepherdHookProducerState.readRegisteredLaunch(
            bytes, hostInstance: fixture.host, workspaceID: fixture.workspace, surfaceID: fixture.surface,
            qualifiedBinaries: fixture.qualified
        )
        #expect(launch == state.launch)
        #expect(try ShepherdHookProducerState.readStore(
            bytes, matching: fixture.scope, qualifiedBinaries: fixture.qualified
        ) == nil)
        #expect(try ShepherdHookProducerState.readRegisteredLaunch(
            bytes, hostInstance: UUID(), workspaceID: fixture.workspace, surfaceID: fixture.surface,
            qualifiedBinaries: fixture.qualified
        ) == nil)
        #expect(try ShepherdHookProducerState.readRegisteredLaunch(
            bytes, hostInstance: fixture.host, workspaceID: fixture.workspace, surfaceID: fixture.surface
        ) == nil)
    }

    @Test func receiptsWithoutExecutableIdentityCannotCreateAProducer() throws {
        let fixture = ProducerStateFixture()
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fixture.launch)
        ) as? [String: Any])
        object.removeValue(forKey: "executableIdentity")
        let launch = try JSONDecoder().decode(
            ShepherdHookLaunchReceipt.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(ShepherdHookProducerState(
            sessionID: "root", launch: launch, qualifiedBinaries: fixture.qualified
        ) == nil)
    }

    @Test func unqualifiedOrOldHookRuntimesCannotCreateAProducer() throws {
        let fixture = ProducerStateFixture()
        #expect(ShepherdHookProducerState(sessionID: "root", launch: fixture.launch) == nil)
        var old = fixture.launch
        old.agentVersion = "2.1.294"
        #expect(ShepherdHookProducerState(
            sessionID: "root", launch: old,
            qualifiedBinaries: ["2.1.294": [fixture.executableDigest]]
        ) == nil)
        var changed = fixture.launch
        changed.executableSHA256 = String(repeating: "c", count: 64)
        #expect(ShepherdHookProducerState(
            sessionID: "root", launch: changed, qualifiedBinaries: fixture.qualified
        ) == nil)
    }

    @Test func onlyAnExactCurrentTopLevelStopCanSealTheWorkEpoch() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        #expect(state.proof?.version == 2)
        #expect(state.proof?.scope == fixture.scope)
        #expect(state.proof(matching: fixture.scope, qualifiedBinaries: fixture.qualified) != nil)
        #expect(state.proof(matching: fixture.scope) == nil)
    }

    @Test(arguments: ["missing-prompt", "old-prompt", "subagent", "failure", "missing-tasks",
                      "missing-crons", "tasks", "cron", "scope", "birth", "epoch"])
    func incompleteOrStaleStopsNeverProduceReadiness(change: String) throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        var stop = fixture.stop(prompt: prompt)
        var scope = fixture.scope
        switch change {
        case "missing-prompt": stop.removeValue(forKey: "prompt_id")
        case "old-prompt": stop["prompt_id"] = UUID().uuidString
        case "subagent": stop["hook_event_name"] = "SubagentStop"
        case "failure": stop["hook_event_name"] = "StopFailure"
        case "missing-tasks": stop.removeValue(forKey: "background_tasks")
        case "missing-crons": stop.removeValue(forKey: "session_crons")
        case "tasks": stop["background_tasks"] = [["status": "running"]]
        case "cron": stop["session_crons"] = [["recurring": false]]
        case "scope": scope.surfaceID = UUID()
        case "birth": scope.pidStartMicroseconds += 1
        case "epoch": _ = state.invalidate(promptID: prompt)
        default: Issue.record("Unhandled fixture")
        }
        let sealed = state.seal(
            stopInput: stop, scope: scope, expectedWorkRevision: revision
        )
        #expect(!sealed)
        #expect(state.proof == nil)
    }

    @Test func newWorkConsumesReadinessAndALateStopCannotRegrantIt() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        let next = state.invalidate(promptID: UUID())
        #expect(next != revision)
        #expect(state.proof == nil)
        let resealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(!resealed)
        #expect(state.proof == nil)
    }

    @Test func anIncompleteCurrentStopWithdrawsAnEarlierProof() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        var incomplete = fixture.stop(prompt: prompt)
        incomplete.removeValue(forKey: "session_crons")
        let resealed = state.seal(
            stopInput: incomplete, scope: fixture.scope, expectedWorkRevision: revision
        )
        #expect(!resealed)
        #expect(state.proof == nil)
    }

    @Test func aStaleCompareAndSetCannotEraseANewerProof() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let previous = state.invalidate(promptID: UUID())
        let prompt = UUID()
        let current = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: current
        )
        #expect(sealed)
        let proof = try #require(state.proof)
        let stale = state.seal(
            stopInput: [:], scope: fixture.scope, expectedWorkRevision: previous
        )
        #expect(!stale)
        #expect(state.proof == proof)
    }

    @Test func lateQueuedLifecycleCannotEraseOrRegrantProducerAuthority() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        let ready = try ShepherdHookProducerState.readStore(
            fixture.storeData(state: state, settled: false, event: "UserPromptSubmit", depth: 1),
            matching: fixture.scope, qualifiedBinaries: fixture.qualified
        )
        #expect(ready?.proof == state.proof)
        _ = state.invalidate(promptID: UUID())
        let held = try ShepherdHookProducerState.readStore(
            fixture.storeData(state: state, settled: true, event: "Stop", depth: 0),
            matching: fixture.scope, qualifiedBinaries: fixture.qualified
        )
        #expect(held == nil)
    }

    @Test func anUnqualifiedReaderCannotTrustAQualifiedLookingPersistedProducer() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        let result = try ShepherdHookProducerState.readStore(
            fixture.storeData(state: state, settled: true, event: "Stop", depth: 0),
            matching: fixture.scope
        )
        #expect(result == nil)
    }

    @Test(arguments: ["session", "owner", "pid", "birth", "epoch", "prompt", "version",
                      "binary", "settings", "legacy", "diagnostic"])
    func aPersistedClaimCannotBorrowAnotherEpochOrLegacyTelemetry(change: String) throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        var store = try #require(JSONSerialization.jsonObject(
            with: fixture.storeData(state: state, settled: true, event: "Stop", depth: 0)
        ) as? [String: Any])
        var sessions = try #require(store["sessions"] as? [String: Any])
        var record = try #require(sessions["root"] as? [String: Any])
        var producer = try #require(record["shepherdProducer"] as? [String: Any])
        var proof = try #require(producer["proof"] as? [String: Any])
        var launch = try #require(producer["launch"] as? [String: Any])
        switch change {
        case "session": record["sessionId"] = "other"
        case "owner":
            store["activeSessionsBySurface"] = [fixture.surface.uuidString: ["sessionId": "other"]]
        case "pid": record["pid"] = 43
        case "birth": record["pidStartMicroseconds"] = 201
        case "epoch": producer["workRevision"] = UUID().uuidString
        case "prompt": producer["promptID"] = UUID().uuidString
        case "version": proof["version"] = 1
        case "binary": launch["executableSHA256"] = String(repeating: "c", count: 64)
        case "settings": launch["settingsSHA256"] = "not-a-digest"
        case "legacy":
            proof["version"] = 1
            record["shepherdReadiness"] = proof
        case "diagnostic":
            record["queuedGuardRevision"] = producer["workRevision"]
            record["queuedGuardPrompt"] = producer["promptID"]
            record["queuedGuardProof"] = proof
            producer.removeValue(forKey: "proof")
        default: Issue.record("Unhandled fixture")
        }
        producer["proof"] = change == "diagnostic" ? nil : proof
        producer["launch"] = launch
        record["shepherdProducer"] = change == "legacy" ? nil : producer
        sessions["root"] = record
        store["sessions"] = sessions
        let result = try ShepherdHookProducerState.readStore(
            JSONSerialization.data(withJSONObject: store),
            matching: fixture.scope, qualifiedBinaries: fixture.qualified
        )
        #expect(result == nil)
    }

    @Test func malformedSiblingRecordsCannotBeDroppedToProduceReadiness() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        var store = try #require(JSONSerialization.jsonObject(
            with: fixture.storeData(state: state, settled: true, event: "Stop", depth: 0)
        ) as? [String: Any])
        var sessions = try #require(store["sessions"] as? [String: Any])
        sessions["malformed"] = ["sessionId": 123]
        store["sessions"] = sessions
        let bytes = try JSONSerialization.data(withJSONObject: store)
        #expect(throws: DecodingError.self) {
            try ShepherdHookProducerState.readStore(
                bytes, matching: fixture.scope, qualifiedBinaries: fixture.qualified
            )
        }
    }

    @Test func legacyTelemetrySiblingsHaveNoAuthorityOverTheRegisteredProducer() throws {
        let fixture = ProducerStateFixture()
        var state = try fixture.state()
        let prompt = UUID()
        let revision = fixture.startPrompt(&state, promptID: prompt)
        let sealed = state.seal(
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope,
            expectedWorkRevision: revision
        )
        #expect(sealed)
        var store = try #require(JSONSerialization.jsonObject(
            with: fixture.storeData(state: state, settled: true, event: "Stop", depth: 0)
        ) as? [String: Any])
        var sessions = try #require(store["sessions"] as? [String: Any])
        var sibling = try #require(sessions["root"] as? [String: Any])
        sibling["sessionId"] = "previous"
        sibling.removeValue(forKey: "shepherdProducer")
        sibling["pid"] = 999
        sessions["previous"] = sibling
        store["sessions"] = sessions
        let result = try ShepherdHookProducerState.readStore(
            JSONSerialization.data(withJSONObject: store),
            matching: fixture.scope, qualifiedBinaries: fixture.qualified
        )
        #expect(result?.proof == state.proof)
    }
}

private struct ProducerStateFixture {
    let executableDigest = String(repeating: "a", count: 64)
    let workspace = UUID()
    let surface = UUID()
    let host = UUID()

    var qualified: [String: Set<String>] { ["2.1.295": [executableDigest]] }

    var launch: ShepherdHookLaunchReceipt {
        ShepherdHookLaunchReceipt(
            id: UUID(), hostInstance: host, workspaceID: workspace, surfaceID: surface,
            pid: 42, pidStartSeconds: 100, pidStartMicroseconds: 200,
            executablePath: "/opt/claude/versions/2.1.295",
            executableSHA256: executableDigest,
            settingsSHA256: String(repeating: "b", count: 64), agentVersion: "2.1.295",
            executableIdentity: ShepherdHookExecutableIdentity(
                device: 1, inode: 1, byteCount: 42, modificationSeconds: 1,
                modificationNanoseconds: 0, changeSeconds: 1, changeNanoseconds: 0
            )
        )
    }

    var scope: ShepherdHookReadinessScope {
        ShepherdHookReadinessScope(
            hostInstance: host, workspaceID: workspace, surfaceID: surface,
            processInstance: "42:123456", pid: 42,
            pidStartSeconds: 100, pidStartMicroseconds: 200,
            surfaceGeneration: 1, inputRevision: 0
        )
    }

    func state() throws -> ShepherdHookProducerState {
        try #require(ShepherdHookProducerState(
            sessionID: "root", launch: launch, qualifiedBinaries: qualified
        ))
    }

    func startPrompt(_ state: inout ShepherdHookProducerState, promptID: UUID) -> UUID {
        let revision = state.invalidate(promptID: promptID)
        let captured = state.capturePromptScope(scope, promptID: promptID, expectedWorkRevision: revision)
        #expect(captured)
        return revision
    }

    func stop(prompt: UUID) -> [String: Any] {
        [
            "session_id": "root", "hook_event_name": "Stop",
            "prompt_id": prompt.uuidString, "background_tasks": [], "session_crons": [],
        ]
    }

    func storeData(
        state: ShepherdHookProducerState, settled: Bool, event: String, depth: Int
    ) throws -> Data {
        let producer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        return try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": [
                "root": [
                    "sessionId": "root", "workspaceId": workspace.uuidString,
                    "surfaceId": surface.uuidString, "pid": 42,
                    "pidStartSeconds": 100, "pidStartMicroseconds": 200,
                    "turnSettled": settled, "hookEventName": event, "activePromptDepth": depth,
                    "shepherdProducer": producer,
                ]
            ],
            "activeSessionsBySurface": [surface.uuidString: ["sessionId": "root"]],
        ])
    }
}
