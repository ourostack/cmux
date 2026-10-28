import Foundation
import Darwin
import Testing
@testable import CmuxControlSocket

@Suite struct ShepherdHookReadinessTests {
    private let scope = ShepherdHookReadinessScope(
        hostInstance: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        surfaceID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        processInstance: "42:123456", pid: 42, pidStartSeconds: 100,
        pidStartMicroseconds: 200, surfaceGeneration: 7, inputRevision: 9
    )

    @Test func onlyExplicitCompleteEmptyRegistriesEstablishReadiness() throws {
        let proof = try #require(ShepherdHookReadinessProof(
            stopInput: ["background_tasks": [], "session_crons": []],
            sessionID: "root", scope: scope
        ))
        #expect(proof.version == 1)
        #expect(proof.sessionID == "root")
        #expect(proof.scope == scope)
        #expect(proof.nonce != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        for input: [String: Any] in [
            [:], ["background_tasks": []], ["session_crons": []],
            ["background_tasks": NSNull(), "session_crons": []],
            ["background_tasks": [], "session_crons": false],
            ["background_tasks": [["status": "completed"]], "session_crons": []],
            ["background_tasks": [], "session_crons": [["id": "future-wake"]]],
        ] {
            #expect(ShepherdHookReadinessProof(stopInput: input, sessionID: "root", scope: scope) == nil)
        }
    }

    @Test func legacyPendingFlagsNeverBecomeNegativeAuthority() throws {
        for legacy in [true, false] {
            let data = try store(proof: nil, legacy: legacy)
            #expect(try ShepherdHookReadinessProof.readStore(data, matching: scope) == nil)
        }
    }

    @Test func strictStoreRequiresTheUniqueCurrentRootAndExactNativeScope() throws {
        let proof = try #require(ShepherdHookReadinessProof(
            stopInput: ["background_tasks": [], "session_crons": []], sessionID: "root", scope: scope
        ))
        let data = try store(proof: proof)
        #expect(try ShepherdHookReadinessProof.readStore(data, matching: scope) == proof)
        for field in ["boot", "workspace", "surface", "process", "pid", "seconds",
                      "micros", "generation", "revision"] {
            var changed = scope
            switch field {
            case "boot": changed.hostInstance = UUID()
            case "workspace": changed.workspaceID = UUID()
            case "surface": changed.surfaceID = UUID()
            case "process": changed.processInstance = "42:999"
            case "pid": changed.pid = 43
            case "seconds": changed.pidStartSeconds += 1
            case "micros": changed.pidStartMicroseconds += 1
            case "generation": changed.surfaceGeneration += 1
            default: changed.inputRevision += 1
            }
            #expect(try ShepherdHookReadinessProof.readStore(data, matching: changed) == nil)
        }
        for mutation in ["version", "active", "sibling", "birth", "session", "event", "unsettled", "depth"] {
            #expect(try ShepherdHookReadinessProof.readStore(
                store(proof: proof, mutation: mutation), matching: scope
            ) == nil)
        }
    }

    @Test func malformedOrTruncatedStoreIsNotTolerantlyRecovered() throws {
        let proof = try #require(ShepherdHookReadinessProof(
            stopInput: ["background_tasks": [], "session_crons": []], sessionID: "root", scope: scope
        ))
        var object = try #require(JSONSerialization.jsonObject(with: store(proof: proof)) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [String: Any])
        sessions["broken"] = ["pid": "not-a-pid"]
        object["sessions"] = sessions
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.readStore(
                JSONSerialization.data(withJSONObject: object), matching: scope
            )
        }
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.readStore(Data("{".utf8), matching: scope)
        }
    }

    @Test func scopeCaptureUsesTypedNativeInspectionRatherThanHookPIDHints() throws {
        let captured = try ShepherdHookReadinessScope.capture(
            inspection: inspection(), workspaceID: scope.workspaceID, surfaceID: scope.surfaceID,
            pid: 42, pidStartSeconds: 100, pidStartMicroseconds: 200
        )
        #expect(captured == scope)
        for mutation in ["version", "workspace", "surface", "process", "agent", "generation"] {
            #expect(try ShepherdHookReadinessScope.capture(
                inspection: inspection(mutation: mutation), workspaceID: scope.workspaceID,
                surfaceID: scope.surfaceID, pid: 42, pidStartSeconds: 100, pidStartMicroseconds: 200
            ) == nil)
        }
    }

    @Test func storeReaderIsBoundedAndRejectsUnsafeFileTypesAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("claude-hook-sessions.json")
        let environment = ["CMUX_AGENT_HOOK_STATE_DIR": directory.path]
        #expect(try ShepherdHookReadinessProof.loadStoreData(environment: environment) == nil)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try ShepherdHookReadinessProof.loadStoreData(environment: environment) == Data("{}".utf8))
        let alias = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.loadStoreData(environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": alias.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.loadStoreData(environment: environment)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.loadStoreData(environment: environment)
        }
    }

    @Test func fifoStoreCannotBlockNativeObservationWaitingForAWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("store.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            try ShepherdHookReadinessProof.loadStoreData(environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": fifo.path])
        }
    }

    private func inspection(mutation: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocol_version": mutation == "version" ? 2 : 1,
            "host_instance": scope.hostInstance.uuidString,
            "snapshot": [
                "workspace_id": mutation == "workspace" ? UUID().uuidString : scope.workspaceID.uuidString,
                "surface_id": mutation == "surface" ? UUID().uuidString : scope.surfaceID.uuidString,
                "process_instance": mutation == "process" ? "43:123456" : "42:123456",
                "surface_generation": mutation == "generation" ? 0 : 7,
                "input_revision": 9, "agent": mutation == "agent" ? "codex" : "claude"
            ],
            "screen": "This screen must never appear in the persisted proof.",
            "token": NSNull()
        ])
    }

    private func store(
        proof: ShepherdHookReadinessProof?, legacy: Bool = false, mutation: String = ""
    ) throws -> Data {
        var record: [String: Any] = [
            "sessionId": "root", "workspaceId": scope.workspaceID.uuidString,
            "surfaceId": scope.surfaceID.uuidString, "pid": 42,
            "pidStartSeconds": 100, "pidStartMicroseconds": 200,
            "hookEventName": "Stop", "turnSettled": true, "activePromptDepth": 0,
            "hadPendingBackgroundWorkAtStop": legacy,
        ]
        if let proof {
            record["shepherdReadiness"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))
        }
        switch mutation {
        case "birth": record["pidStartMicroseconds"] = 201
        case "session": record["sessionId"] = "other"
        case "event": record["hookEventName"] = "PreToolUse"
        case "unsettled": record["turnSettled"] = false
        case "depth": record["activePromptDepth"] = 1
        default: break
        }
        var sessions = ["root": record]
        if mutation == "sibling" { sessions["sibling"] = record }
        return try JSONSerialization.data(withJSONObject: [
            "version": mutation == "version" ? 2 : 1,
            "sessions": sessions,
            "activeSessionsBySurface": [
                scope.surfaceID.uuidString: ["sessionId": mutation == "active" ? "other" : "root"]
            ],
        ])
    }
}
