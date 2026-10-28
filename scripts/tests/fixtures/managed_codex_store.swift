import CmuxControlSocket
import Darwin
import Foundation

@main
struct ManagedCodexStoreFixture {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.count == 2, args[0] == "--fixture-codex-store" {
                guard let request = try JSONSerialization.jsonObject(
                    with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any] else {
                    throw POSIXError(.EPROTO)
                }
                let result = try await run(args[1], request: request)
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                return
            }
            if args.count == 5, args[0] == "--private-stdio", args[1] == "--boot-nonce", args[3] == "--cwd" {
                try ManagedCodexSessionFixture.peer(nonce: args[2], directory: args[4])
                return
            }
            if args == ["--headless", "--no-auto-update", "--stdio", "--allow-all"] {
                try ManagedCopilotStartupFixture.peer("owner-tool-native-coding")
                return
            }
            guard let command = args.first, let supervisor = try OwnedProcessSupervisor(
                command: command, arguments: Array(args.dropFirst())) else { throw POSIXError(.EINVAL) }
            exit(try supervisor.run())
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run(_ scenario: String, request: [String: Any]) async throws -> [String: Any] {
        let store = AgentSessionProcessStore(), foreignStore = AgentSessionProcessStore()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-codex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var config = request
        let useCopilot = scenario == "copilot-control"
        let projectFile = directory.appendingPathComponent("controlled-project.txt")
        if useCopilot {
            try Data("before\n".utf8).write(to: projectFile)
            try JSONSerialization.data(withJSONObject: [
                "scenario": "owner-tool-native-coding", "callbackFile": projectFile.path,
            ]).write(to: directory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        }
        config["scenario"] = scenario == "command" ? "command" : "owner"
        try JSONSerialization.data(withJSONObject: config)
            .write(to: directory.appendingPathComponent(".controlled-codex-config"))
        let ownerStore = scenario == "foreign-store" ? foreignStore : store
        let provider: ShepherdManagedProvider = scenario == "wrong-provider" || useCopilot ? .copilot : .codex
        let candidate: AgentSessionManagedNativeOwner?
        if scenario == "production-unqualified" {
            candidate = .issueForFreshNativePanel(
                newPanelID: UUID(), workspaceID: UUID(), rendererID: "react",
                workingDirectory: directory.path, owningStore: ownerStore, isCurrentOwner: { true }, provider: provider)
        } else {
            candidate = .init(
                newPanelID: UUID(), workspaceID: UUID(), rendererID: "react",
                workingDirectory: directory.path, owningStore: ownerStore, isCurrentOwner: { true }, provider: provider)
        }
        guard let owner = candidate else { throw POSIXError(.EPERM) }
        var events: [[String: Any]] = []
        store.eventSink = { events.append($0) }
        var startError = "", sessionID = ""
        do {
            if useCopilot {
                sessionID = try await store.startManagedCopilot(
                    scope: owner.scope, executableURL: executable, workingDirectory: directory.path,
                    codingProjectMandate: owner.projectMandate, nativeCodingOwner: owner,
                    launcher: .init(supervisorExecutableURL: executable)).sessionId
            } else {
                sessionID = try await store.startManagedCodex(
                    scope: owner.scope, executableURL: executable, workingDirectory: directory.path,
                    nativeCodingOwner: owner, launcher: .init(supervisorExecutableURL: executable)).sessionId
            }
        } catch { startError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error) }
        let owned = store.ownsManagedCodingOwner(owner)
        let snapshot = store.nativeManagedSessionSnapshot
        var managedDuplicateError = "", manualDuplicateError = ""
        if scenario == "mixed-slot", startError.isEmpty {
            do {
                _ = try await store.startManagedCopilot(
                    scope: owner.scope, executableURL: executable, workingDirectory: directory.path,
                    codingProjectMandate: nil, launcher: .init(supervisorExecutableURL: executable))
            } catch { managedDuplicateError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error) }
            do {
                _ = try await store.start(
                    plan: .init(provider: .claude, executableURL: executable, arguments: [], environment: [:]),
                    workingDirectory: directory.path, launcher: .init(supervisorExecutableURL: executable))
            } catch { manualDuplicateError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error) }
        }
        if startError.isEmpty {
            try await store.writeLine(
                sessionId: sessionID, text: useCopilot ? "Owner input: 雪 🐈" : "controlled owner: 雪")
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while store.managedCodingState(for: owner)?.hasCompleteWorkEvidence != true,
                  ContinuousClock.now < deadline, store.hasActiveProviderSession {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let state = store.managedCodingState(for: owner)
        let complete = state?.hasCompleteWorkEvidence == true
        let identityMatches = state?.identity.provider == (useCopilot ? .copilot : .codex)
            && (useCopilot ? (state?.identity.providerSessionID).flatMap { UUID(uuidString: $0) } != nil
                : state?.identity.providerSessionID == "actual-controlled-sdk-thread")
        if scenario == "revoked" { owner.revoke() }
        else { store.closeAll() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while store.hasActiveProviderSession, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let executions = useCopilot
            ? URL(fileURLWithPath: projectFile.path + ".executions") : directory.appendingPathComponent("executions")
        return [
            "startError": startError, "owned": owned, "provider": snapshot?["providerId"] as? String ?? "",
            "identityMatches": identityMatches, "complete": complete, "completeBeforeClose": complete,
            "managedDuplicateError": managedDuplicateError, "manualDuplicateError": manualDuplicateError,
            "peerStarted": FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".controlled-codex-started").path),
            "providerStarted": events.contains { $0["type"] as? String == "provider.started" },
            "assistant": events.filter { $0["type"] as? String == "provider.output" && $0["stream"] as? String == "stdout" }
                .compactMap { $0["text"] as? String }.joined(),
            "turnCompletions": events.filter { $0["type"] as? String == "provider.turnComplete" }.count,
            "eventsMatchSession": !events.isEmpty && events.allSatisfy {
                $0["providerId"] as? String == (useCopilot ? "copilot" : "codex")
                    && $0["sessionId"] as? String == sessionID
            },
            "exitStatuses": events.filter { $0["type"] as? String == "provider.exit" }.compactMap { $0["status"] as? Int },
            "commandStatuses": events.filter { $0["type"] as? String == "provider.activity" }
                .compactMap { $0["status"] as? String },
            "executions": FileManager.default.fileExists(atPath: executions.path)
                ? try String(contentsOf: executions, encoding: .utf8) : "",
            "projectContents": useCopilot ? try String(contentsOf: projectFile, encoding: .utf8) : "",
            "revocationReported": events.contains {
                ($0["text"] as? String)?.contains("nativeOwnerRevoked") == true
            },
            "stopped": !store.hasActiveProviderSession,
        ]
    }
}
