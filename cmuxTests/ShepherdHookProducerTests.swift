#if SHEPHERD_SOURCE_TEST
import CmuxControlSocket
import CmuxFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import cmux

@Suite(.serialized) struct ShepherdHookProducerTests {
    @Test func synchronousProducerStateSurvivesItsOwnQueuedMetadataAndRejectsALateStop() throws {
        let fixture = ProducerFixture()
        let launch = fixture.launch()
        try fixture.store.installShepherdLaunch(
            launch, qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        let prompt = UUID()
        let revision = try fixture.store.beginShepherdProducerEvent(
            launchID: launch.id, sessionID: "root", event: "UserPromptSubmit", promptID: prompt,
            qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        let observed = try fixture.store.captureShepherdPromptScope(
            launchID: launch.id, sessionID: "root", promptID: prompt, expectedWorkRevision: revision,
            scope: fixture.scope(), qualifiedBinaries: fixture.qualified,
            processIdentity: { _ in fixture.birth }
        )
        #expect(observed)
        let sealed = try fixture.store.commitShepherdProducerReadiness(
            launchID: launch.id, sessionID: "root", expectedWorkRevision: revision,
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope(),
            qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        #expect(sealed)
        let proof = try #require(fixture.store.state.sessions["root"]?.shepherdProducer?.proof)
        try fixture.store.invalidateShepherdReadiness(sessionId: "root")
        #expect(fixture.store.state.sessions["root"]?.shepherdProducer?.proof == proof)
        _ = try fixture.store.beginShepherdProducerEvent(
            launchID: launch.id, sessionID: "root", event: "UserPromptSubmit", promptID: UUID(),
            qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        let stale = try fixture.store.commitShepherdProducerReadiness(
            launchID: launch.id, sessionID: "root", expectedWorkRevision: revision,
            stopInput: fixture.stop(prompt: prompt), scope: fixture.scope(),
            qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        #expect(!stale)
        #expect(fixture.store.state.sessions["root"]?.shepherdProducer?.proof == nil)
    }

    @Test func failedRetirementCannotReportASuccessfulLaunch() throws {
        let fixture = ProducerFixture()
        fixture.store.failPersistence = true
        #expect(throws: CLIError.self) {
            try fixture.store.installShepherdLaunch(
                fixture.launch(), qualifiedBinaries: fixture.qualified,
                processIdentity: { _ in fixture.birth }
            )
        }
        #expect(fixture.store.state.sessions.count == 1)
    }

    @Test func identicalLaunchReentryRevokesReadinessAndCannotDowngradeTheReceipt() throws {
        let fixture = ProducerFixture()
        let launch = fixture.launch()
        try fixture.prepareProducer(launch)
        let prior = try #require(fixture.store.state.sessions["root"]?.shepherdProducer)
        #expect(prior.proof != nil)
        try fixture.store.installShepherdLaunch(
            launch, qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
        )
        let next = try #require(fixture.store.state.sessions["root"]?.shepherdProducer)
        #expect(next.launch == launch)
        #expect(next.workRevision != prior.workRevision)
        #expect(next.proof == nil)
        #expect(throws: CLIError.self) {
            try fixture.store.installShepherdLaunch(
                fixture.launch(), qualifiedBinaries: fixture.qualified,
                processIdentity: { _ in fixture.birth }
            )
        }
        #expect(fixture.store.state.sessions["root"]?.shepherdProducer == next)
    }

    @Test func failedWorkInvalidationCannotAcknowledgeOrChangeTheStoredEpoch() throws {
        let fixture = ProducerFixture()
        let launch = fixture.launch()
        try fixture.prepareProducer(launch)
        let prior = try #require(fixture.store.state.sessions["root"]?.shepherdProducer)
        fixture.store.failPersistence = true
        #expect(throws: CLIError.self) {
            try fixture.store.beginShepherdProducerEvent(
                launchID: launch.id, sessionID: "root", event: "UserPromptSubmit", promptID: UUID(),
                qualifiedBinaries: fixture.qualified, processIdentity: { _ in fixture.birth }
            )
        }
        #expect(fixture.store.state.sessions["root"]?.shepherdProducer == prior)
    }

    @Test func launchLookupIsReadOnlyAndCannotAcknowledgeARequiredWrite() throws {
        let fixture = ProducerFixture()
        let launch = fixture.launch()
        try fixture.prepareProducer(launch)
        let producer = try #require(fixture.store.state.sessions["root"]?.shepherdProducer)
        fixture.store.failPersistence = true
        #expect(try fixture.store.lookupShepherdLaunch(id: launch.id) == launch)
        #expect(try fixture.store.lookupShepherdLaunch(root: fixture.birth) == launch)
        #expect(fixture.store.state.sessions["root"]?.shepherdProducer == producer)
    }

    @Test(arguments: ["workspace", "surface", "pid", "birth", "metadata"])
    func onlyOwnershipChangesRetireProducerAuthority(change: String) throws {
        let fixture = ProducerFixture()
        try fixture.prepareProducer(fixture.launch())
        var record = try #require(fixture.store.state.sessions["root"])
        let producer = try #require(record.shepherdProducer)
        switch change {
        case "workspace": record.workspaceId = UUID().uuidString
        case "surface": record.surfaceId = UUID().uuidString
        case "pid": record.pid = 43
        case "birth": record.pidStartMicroseconds = 201
        default:
            record.turnSettled = false
            record.hookEventName = "UserPromptSubmit"
            record.activePromptDepth = 1
        }
        record.retireShepherdProducerIfOwnershipChanged()
        #expect(record.shepherdProducer == (change == "metadata" ? producer : nil))
    }

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
    let executableDigest = String(repeating: "a", count: 64)

    var qualified: [String: Set<String>] { ["2.1.295": [executableDigest]] }

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

    func launch() -> ShepherdHookLaunchReceipt {
        ShepherdHookLaunchReceipt(
            id: UUID(), hostInstance: boot, workspaceID: workspace, surfaceID: surface,
            pid: 42, pidStartSeconds: 100, pidStartMicroseconds: 200,
            executablePath: "/opt/claude/versions/2.1.295", executableSHA256: executableDigest,
            settingsSHA256: String(repeating: "b", count: 64), agentVersion: "2.1.295",
            executableIdentity: ShepherdHookExecutableIdentity(
                device: 1, inode: 1, byteCount: 42, modificationSeconds: 1,
                modificationNanoseconds: 0, changeSeconds: 1, changeNanoseconds: 0
            )
        )
    }

    func scope() -> ShepherdHookReadinessScope {
        ShepherdHookReadinessScope(
            hostInstance: boot, workspaceID: workspace, surfaceID: surface,
            processInstance: "42:123456", pid: 42, pidStartSeconds: 100,
            pidStartMicroseconds: 200, surfaceGeneration: 1, inputRevision: 0
        )
    }

    func stop(prompt: UUID) -> [String: Any] {
        [
            "session_id": "root", "hook_event_name": "Stop", "prompt_id": prompt.uuidString,
            "background_tasks": [], "session_crons": [],
        ]
    }

    func prepareProducer(_ launch: ShepherdHookLaunchReceipt) throws {
        try store.installShepherdLaunch(
            launch, qualifiedBinaries: qualified, processIdentity: { _ in birth }
        )
        let prompt = UUID()
        let revision = try store.beginShepherdProducerEvent(
            launchID: launch.id, sessionID: "root", event: "UserPromptSubmit", promptID: prompt,
            qualifiedBinaries: qualified, processIdentity: { _ in birth }
        )
        let observed = try store.captureShepherdPromptScope(
            launchID: launch.id, sessionID: "root", promptID: prompt, expectedWorkRevision: revision,
            scope: scope(), qualifiedBinaries: qualified, processIdentity: { _ in birth }
        )
        #expect(observed)
        let sealed = try store.commitShepherdProducerReadiness(
            launchID: launch.id, sessionID: "root", expectedWorkRevision: revision,
            stopInput: stop(prompt: prompt), scope: scope(),
            qualifiedBinaries: qualified, processIdentity: { _ in birth }
        )
        #expect(sealed)
    }
}

@Suite(.serialized) struct ShepherdHookExecutableVerifierTests {
    @Test func unqualifiedLaunchesDoNotEvenExecuteTheVersionProbe() throws {
        let fixture = try executableProbeFixture(name: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try ShepherdHookExecutableVerifier.verify(path: fixture.executable.path)?.digest == nil)
        #expect(try ShepherdHookExecutableVerifier.verify(
            path: fixture.executable.path, qualifiedBinaries: ["2.1.295": [String(repeating: "0", count: 64)]]
        )?.digest == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".ran"))
    }

    @Test func anExplicitQualifiedLaunchBindsRealFileIdentityAndExactVersionOutput() throws {
        let fixture = try executableProbeFixture(name: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try ShepherdHookExecutableVerifier.verify(
            path: fixture.executable.path, qualifiedBinaries: ["2.1.295": [fixture.digest]]
        )
        let verified = try #require(result)
        #expect(verified.canonicalPath == fixture.executable.path)
        #expect(verified.digest == fixture.digest)
        #expect(verified.version == "2.1.295")
        #expect(try ShepherdHookExecutableIdentity.capture(path: verified.canonicalPath) == verified.identity)
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".ran"))
    }

    @Test(arguments: ["large", "slow", "old", "ambiguous", "changed", "error"])
    func failedOrUnboundedVersionProbesCannotRegisterALaunch(name: String) throws {
        let fixture = try executableProbeFixture(name: name)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) {
            try ShepherdHookExecutableVerifier.verify(
                path: fixture.executable.path, qualifiedBinaries: ["2.1.295": [fixture.digest]]
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".ran"))
        let rawPID = try String(contentsOfFile: fixture.executable.path + ".ran", encoding: .utf8)
        let pid = try #require(Int32(rawPID))
        #expect(kill(pid, 0) == -1)
    }

    @Test func interpreterScriptsCannotMasqueradeAsAQualifiedNativeRuntime() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf ran > \"$0.ran\"\nprintf '2.1.295 (Claude Code)\\n'\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let digest = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        #expect(throws: CLIError.self) {
            try ShepherdHookExecutableVerifier.verify(
                path: file.path, qualifiedBinaries: ["2.1.295": [digest]]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path + ".ran"))
    }
}

private func executableProbeFixture(name: String) throws -> (root: URL, executable: URL, digest: String) {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let executable = root.appendingPathComponent(name)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["clang", "-Werror", "-x", "c", "-", "-o", executable.path]
    let input = Pipe()
    compiler.standardInput = input
    try compiler.run()
    try input.fileHandleForWriting.write(contentsOf: Data(#"""
    #include <stdio.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
        char marker[4096];
        snprintf(marker, sizeof(marker), "%s.ran", argv[0]);
        FILE *f = fopen(marker, "w");
        if (!f) return 1;
        fprintf(f, "%ld", (long)getpid());
        fclose(f);
        if (strstr(argv[0], "/error")) return 7;
        if (strstr(argv[0], "/large")) {
            for (int i = 0; i < 65536; i++) putchar('x');
            return 0;
        }
        if (strstr(argv[0], "/slow")) sleep(5);
        if (strstr(argv[0], "/changed")) chmod(argv[0], 0500);
        if (strstr(argv[0], "/old")) puts("2.1.294 (Claude Code)");
        else if (strstr(argv[0], "/ambiguous")) puts("2.1.295 (Claude Code)\nextra output");
        else puts("2.1.295 (Claude Code)");
        return 0;
    }
    """#.utf8))
    try input.fileHandleForWriting.close()
    compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0)
    let digest = SHA256.hash(data: try Data(contentsOf: executable))
        .map { String(format: "%02x", $0) }.joined()
    return (root, executable, digest)
}
#endif
