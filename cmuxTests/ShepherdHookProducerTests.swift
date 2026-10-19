#if SHEPHERD_SOURCE_TEST
import CmuxControlSocket
import CmuxFoundation
import Foundation
import Testing
@testable import cmux

@Suite(.serialized) struct ShepherdHookProducerTests {
    @Test func commitRequiresTheUnchangedActiveRootAndBracketsItsNativeBirth() throws {
        let fixture = ProducerFixture()
        let proof = try fixture.proof()
        #expect(try fixture.store.commitShepherdReadiness(
            proof, expectedWorkRevision: fixture.revision, processIdentity: { fixture.birth }
        ))
        #expect(fixture.store.state.sessions["root"]?.shepherdReadiness == proof)
        #expect(fixture.store.state.sessions["root"]?.activePromptDepth == 0)
    }

    @Test(arguments: ["revision", "active", "session", "pid", "birth", "running", "event", "nested", "dropped", "reuse"])
    func interveningWorkOrOwnershipChangeCannotBeOverwrittenByALateStop(change: String) throws {
        let fixture = ProducerFixture()
        let proof = try fixture.proof()
        switch change {
        case "revision": try fixture.store.invalidateShepherdReadiness(sessionId: "root")
        case "active": fixture.store.state.activeSessionsBySurface[fixture.surface.uuidString]?.sessionId = "other"
        case "session": fixture.store.state.sessions["root"]?.sessionId = "other"
        case "pid": fixture.store.state.sessions["root"]?.pid = 43
        case "birth": fixture.store.state.sessions["root"]?.pidStartMicroseconds = 201
        case "running": fixture.store.state.sessions["root"]?.turnSettled = false
        case "event": fixture.store.state.sessions["root"]?.hookEventName = "UserPromptSubmit"
        case "nested": fixture.store.state.sessions["root"]?.activePromptDepth = 1
        case "dropped": fixture.store.state.decodeDiagnostics.droppedCount = 1
        default: break
        }
        var reads = 0
        #expect(try !fixture.store.commitShepherdReadiness(
            proof, expectedWorkRevision: fixture.revision, processIdentity: {
                reads += 1
                return change == "reuse" && reads > 1 ? nil : fixture.birth
            }
        ))
        #expect(fixture.store.state.sessions["root"]?.shepherdReadiness == nil)
    }

    @Test func invalidationRemovesProofBeforeAnyNewWorkCanCommit() throws {
        let fixture = ProducerFixture()
        let proof = try fixture.proof()
        #expect(try fixture.store.commitShepherdReadiness(
            proof, expectedWorkRevision: fixture.revision, processIdentity: { fixture.birth }
        ))
        try fixture.store.invalidateShepherdReadiness(sessionId: "root")
        #expect(fixture.store.state.sessions["root"]?.shepherdReadiness == nil)
        #expect(fixture.store.state.sessions["root"]?.shepherdWorkRevision != fixture.revision)
        #expect(try !fixture.store.commitShepherdReadiness(
            proof, expectedWorkRevision: fixture.revision, processIdentity: { fixture.birth }
        ))
    }

    @Test(arguments: [false, true])
    func nativeCapturePersistsNoScreenAndCannotRaceNewWork(interveningWork: Bool) throws {
        let fixture = ProducerFixture()
        let accepted = try fixture.store.recordShepherdReadiness(
            sessionID: "root", workspaceID: fixture.workspace, surfaceID: fixture.surface,
            stopInput: ["background_tasks": [], "session_crons": []],
            inspection: {
                if interveningWork { try fixture.store.invalidateShepherdReadiness(sessionId: "root") }
                return [
                    "protocol_version": 1, "host_instance": fixture.boot.uuidString,
                    "snapshot": [
                        "workspace_id": fixture.workspace.uuidString,
                        "surface_id": fixture.surface.uuidString, "process_instance": "42:123456",
                        "surface_generation": 1, "input_revision": 0, "agent": "claude"
                    ],
                    "screen": "private terminal data", "token": NSNull()
                ]
            },
            processIdentity: { _ in fixture.birth }
        )
        #expect(accepted == !interveningWork)
        #expect((fixture.store.state.sessions["root"]?.shepherdReadiness != nil) == !interveningWork)
        if let proof = fixture.store.state.sessions["root"]?.shepherdReadiness {
            #expect(!String(decoding: try JSONEncoder().encode(proof), as: UTF8.self).contains("private terminal data"))
        }
    }

    @Test func absentCompleteRegistryNeverEvenRequestsANativeSeal() throws {
        let fixture = ProducerFixture()
        #expect(try !fixture.store.recordShepherdReadiness(
            sessionID: "root", workspaceID: fixture.workspace, surfaceID: fixture.surface,
            stopInput: ["hadPendingBackgroundWorkAtStop": false],
            inspection: {
                Issue.record("An absent complete registry reached native proof capture.")
                return [:]
            },
            processIdentity: { _ in fixture.birth }
        ))
    }
}

private final class ProducerFixture {
    let store = ClaudeHookSessionStore()
    let revision = UUID()
    let boot = UUID()
    let workspace = UUID()
    let surface = UUID()
    let birth = AgentPIDProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 200)

    init() {
        store.state.sessions["root"] = ClaudeHookSessionRecord(
            sessionId: "root", workspaceId: workspace.uuidString, surfaceId: surface.uuidString,
            pid: 42, pidStartSeconds: 100, pidStartMicroseconds: 200,
            turnSettled: true, hookEventName: "Stop", activePromptDepth: nil,
            shepherdReadiness: nil, shepherdWorkRevision: revision
        )
        store.state.activeSessionsBySurface[surface.uuidString] = ClaudeHookActiveSessionRecord(sessionId: "root")
    }

    func proof() throws -> ShepherdHookReadinessProof {
        try #require(ShepherdHookReadinessProof(
            stopInput: ["background_tasks": [], "session_crons": []],
            sessionID: "root", scope: ShepherdHookReadinessScope(
                hostInstance: boot, workspaceID: workspace, surfaceID: surface,
                processInstance: "42:123456", pid: 42, pidStartSeconds: 100,
                pidStartMicroseconds: 200, surfaceGeneration: 1, inputRevision: 0
            )
        ))
    }
}
#endif
