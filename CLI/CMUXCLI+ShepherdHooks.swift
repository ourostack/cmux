import CMUXAgentLaunch
import CmuxControlSocket
import CmuxFoundation
import CryptoKit
import Darwin
import Foundation

extension CMUXCLI {
    func runShepherdHookNoSocketCommand(
        commandArgs: [String], socketPath: String, socketPassword: String?
    ) throws -> Bool {
        switch commandArgs.first {
        case "prepare-readiness":
            try prepareShepherdReadiness(
                arguments: Array(commandArgs.dropFirst()), socketPath: socketPath,
                socketPassword: socketPassword
            )
            return true
        case "readiness-event":
            let event = commandArgs.dropFirst().first ?? ""
            do {
                try runShepherdReadinessEvent(
                    arguments: Array(commandArgs.dropFirst()), socketPath: socketPath,
                    socketPassword: socketPassword
                )
            } catch {
                throw CLIError(
                    message: "Shepherd readiness unavailable; no work readiness was granted: \(error)",
                    exitCode: event == "UserPromptSubmit" || event == "PreToolUse" ? 2 : 1
                )
            }
            return true
        default:
            return false
        }
    }

    private func prepareShepherdReadiness(
        arguments: [String], socketPath: String, socketPassword: String?
    ) throws {
        guard arguments.count == 6,
              Set([arguments[0], arguments[2], arguments[4]])
                == Set(["--executable", "--settings", "--root-pid"]),
              let executable = optionValue(arguments, name: "--executable"),
              let settingsPath = optionValue(arguments, name: "--settings"),
              let rootPID = optionValue(arguments, name: "--root-pid").flatMap(Int32.init), rootPID > 1 else {
            throw CLIError(message: "Usage: cmux hooks claude prepare-readiness --executable PATH --settings PATH --root-pid PID")
        }
        let environment = ProcessInfo.processInfo.environment
        guard !ShepherdHookLaunchPolicy.qualifiedBinaries.isEmpty,
              environment["CMUX_CLAUDE_HEADLESS"] != "1",
              environment["CMUX_RELAY_ID"]?.isEmpty != false,
              environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] != "1" else {
            print(settingsPath)
            return
        }
        guard let birth = AgentPIDProcessIdentity(pid: rootPID), shepherdRootIsAncestor(birth) else {
            throw CLIError(message: "Shepherd readiness preparation requires its live launch ancestor.")
        }
        guard let verified = try ShepherdHookExecutableVerifier.verify(path: executable) else {
            print(settingsPath)
            return
        }
        guard let workspaceID = environment["CMUX_WORKSPACE_ID"].flatMap(UUID.init(uuidString:)),
              let surfaceID = environment["CMUX_SURFACE_ID"].flatMap(UUID.init(uuidString:)),
              let cliPath = ShepherdHookExecutableIdentity.kernelExecutablePath(pid: getpid()) else {
            throw CLIError(message: "Shepherd readiness preparation requires exact local launch and CLI identities.")
        }
        let host = try withShepherdClient(socketPath: socketPath, socketPassword: socketPassword) { client in
            try shepherdQualifiedHost(client: client, workspaceID: workspaceID, surfaceID: surfaceID)
        }
        guard let host else {
            print(settingsPath)
            return
        }
        let settings = try readPrivateShepherdSettings(path: settingsPath)
        let object = try JSONSerialization.jsonObject(with: settings) as? [String: Any]
        let store = ClaudeHookSessionStore()
        if object?["disableAllHooks"] as? Bool == true {
            try store.retireShepherdLaunches(surfaceID: surfaceID)
            print(settingsPath)
            return
        }
        let previous = try store.lookupShepherdLaunch(root: birth)
        let launchID = previous?.id ?? UUID()
        let guarded = try ShepherdHookSettings.upgrade(
            settings: settings, managedSettings: Self.claudeWrapperInjectSettingsData(),
            launchID: launchID, cliPath: cliPath
        )
        let artifact = try writePrivateShepherdSettings(guarded, beside: settingsPath)
        let launch = ShepherdHookLaunchReceipt(
            id: launchID, hostInstance: host, workspaceID: workspaceID, surfaceID: surfaceID,
            pid: rootPID, pidStartSeconds: birth.startSeconds, pidStartMicroseconds: birth.startMicroseconds,
            executablePath: verified.canonicalPath, executableSHA256: verified.digest,
            settingsSHA256: Self.shepherdDigest(guarded), agentVersion: verified.version,
            executableIdentity: verified.identity
        )
        guard shepherdRootIsAncestor(birth),
              try readPrivateShepherdSettings(path: artifact) == guarded,
              try ShepherdHookExecutableIdentity.capture(path: verified.canonicalPath) == verified.identity else {
            throw CLIError(message: "Shepherd launch bindings changed before their registration committed.")
        }
        try store.installShepherdLaunch(launch, processIdentity: { AgentPIDProcessIdentity(pid: $0) })
        print(artifact)
    }

    private func runShepherdReadinessEvent(
        arguments: [String], socketPath: String, socketPassword: String?
    ) throws {
        let subcommands = [
            "SessionStart": "session-start", "SessionEnd": "session-end",
            "UserPromptSubmit": "prompt-submit", "PreToolUse": "pre-tool-use",
            "Stop": "stop", "StopFailure": "stop",
        ]
        guard arguments.count == 3, let event = arguments.first, let subcommand = subcommands[event],
              arguments[1] == "--launch", let launchID = UUID(uuidString: arguments[2]),
              !ShepherdHookLaunchPolicy.qualifiedBinaries.isEmpty else {
            throw CLIError(message: "This hook has no supported, build-qualified Shepherd launch.")
        }
        let store = ClaudeHookSessionStore()
        guard let launch = try store.lookupShepherdLaunch(id: launchID),
              launch.isQualified(using: ShepherdHookLaunchPolicy.qualifiedBinaries) else {
            throw CLIError(message: "This hook has no intact qualified Shepherd registration.")
        }
        let root = try validateShepherdHookRoot(launch)
        guard let raw = Self.readBoundedAgentHookInput(requiresEOF: true),
              let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              input["hook_event_name"] as? String == event,
              let sessionID = input["session_id"] as? String, !sessionID.isEmpty else {
            throw CLIError(message: "Shepherd requires one complete, bounded original hook event.")
        }
        let promptID = (input["prompt_id"] as? String).flatMap(UUID.init(uuidString:))
        let revision = try store.beginShepherdProducerEvent(
            launchID: launchID, sessionID: sessionID, event: event, promptID: promptID,
            processIdentity: { AgentPIDProcessIdentity(pid: $0) }
        )
        try enqueueShepherdTelemetry(
            subcommand: subcommand, rawInput: raw, launch: launch, root: root,
            socketPath: socketPath, socketPassword: socketPassword
        )
        if event == "UserPromptSubmit", let promptID {
            let observed = try withShepherdClient(socketPath: socketPath, socketPassword: socketPassword) { client in
                let before = try shepherdScope(client: client, launch: launch, root: root)
                _ = try validateShepherdHookRoot(launch)
                let after = try shepherdScope(client: client, launch: launch, root: root)
                return before == after ? before : nil
            }
            if let observed {
                _ = try store.captureShepherdPromptScope(
                    launchID: launchID, sessionID: sessionID, promptID: promptID,
                    expectedWorkRevision: revision, scope: observed,
                    processIdentity: { AgentPIDProcessIdentity(pid: $0) }
                )
            } else {
                cliWriteStderr("Shepherd prompt observation was unstable; automatic input remains withheld.\n")
            }
        }
        if event == "Stop" {
            _ = try validateShepherdHookRoot(launch)
            let scope = try withShepherdClient(socketPath: socketPath, socketPassword: socketPassword) { client in
                try shepherdScope(client: client, launch: launch, root: root)
            }
            if let scope {
                _ = try store.commitShepherdProducerReadiness(
                    launchID: launchID, sessionID: sessionID, expectedWorkRevision: revision,
                    stopInput: input, scope: scope, processIdentity: { AgentPIDProcessIdentity(pid: $0) }
                )
            }
        }
        print("{}")
    }

    private func shepherdScope(
        client: SocketClient, launch: ShepherdHookLaunchReceipt, root: AgentPIDProcessIdentity
    ) throws -> ShepherdHookReadinessScope? {
        let inspection = try client.sendV2(method: "surface.shepherd.inspect", params: [
            "workspace_id": launch.workspaceID.uuidString, "surface_id": launch.surfaceID.uuidString
        ], responseTimeout: 1)
        return try ShepherdHookReadinessScope.capture(
            inspection: JSONSerialization.data(withJSONObject: inspection),
            workspaceID: launch.workspaceID, surfaceID: launch.surfaceID, pid: root.pid,
            pidStartSeconds: root.startSeconds, pidStartMicroseconds: root.startMicroseconds
        )
    }

    private func enqueueShepherdTelemetry(
        subcommand: String, rawInput: String, launch: ShepherdHookLaunchReceipt,
        root: AgentPIDProcessIdentity, socketPath: String, socketPassword: String?
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLAUDE_PID"] = String(root.pid)
        environment[AgentHookDeliveryPolicy.invokerPIDEnvironmentKey] = String(root.pid)
        environment["CMUX_WORKSPACE_ID"] = launch.workspaceID.uuidString
        environment["CMUX_SURFACE_ID"] = launch.surfaceID.uuidString
        try withShepherdClient(socketPath: socketPath, socketPassword: socketPassword) { client in
            admitSpooledAgentHooks(
                agent: "claude", client: client, socketPassword: socketPassword,
                processEnvironment: environment
            )
            try admitQueuedAgentHook(
                agent: "claude", subcommand: subcommand, rawPayload: rawInput,
                processEnvironment: environment, client: client, socketPassword: socketPassword,
                // Use the verified root, not a second ancestry inference.
                runsInHookProcess: false
            )
        }
    }

    private func validateShepherdHookRoot(
        _ launch: ShepherdHookLaunchReceipt
    ) throws -> AgentPIDProcessIdentity {
        let pid = getppid()
        guard pid == launch.pid, let birth = AgentPIDProcessIdentity(pid: pid),
              birth.startSeconds == launch.pidStartSeconds,
              birth.startMicroseconds == launch.pidStartMicroseconds,
              ShepherdHookExecutableIdentity.kernelExecutablePath(pid: pid) == launch.executablePath,
              let identity = launch.executableIdentity,
              try ShepherdHookExecutableIdentity.capture(path: launch.executablePath) == identity,
              getppid() == pid, AgentPIDProcessIdentity(pid: pid) == birth else {
            throw CLIError(message: "Shepherd accepts readiness only from its exact live native root hook.")
        }
        return birth
    }

    private func shepherdRootIsAncestor(_ birth: AgentPIDProcessIdentity) -> Bool {
        var cursor = getppid()
        for _ in 0..<16 {
            if cursor == birth.pid { return AgentPIDProcessIdentity(pid: cursor) == birth }
            guard cursor > 1 else { return false }
            let parent = parentPID(of: cursor)
            guard parent > 0, parent != cursor else { return false }
            cursor = parent
        }
        return false
    }

    private func withShepherdClient<T>(
        socketPath: String, socketPassword: String?, _ body: (SocketClient) throws -> T
    ) throws -> T {
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        guard !client.isRelayBacked else {
            throw CLIError(message: "Shepherd hook registration requires a local native socket.")
        }
        let deadline = Date().addingTimeInterval(1)
        try client.connect(deadline: deadline)
        try authenticateClientIfNeeded(
            client, explicitPassword: socketPassword, socketPath: socketPath,
            responseTimeout: 1, deadline: deadline
        )
        return try body(client)
    }

    private func shepherdQualifiedHost(
        client: SocketClient, workspaceID: UUID, surfaceID: UUID
    ) throws -> UUID? {
        let capabilities: [String: Any]
        do {
            capabilities = try client.sendV2(method: "system.capabilities", responseTimeout: 1)
        } catch let error as CLIError where error.isStructuredProtocolResponse && error.v2Code == "method_not_found" {
            return nil
        }
        let discovery = try JSONDecoder().decode(
            ShepherdDiscovery.self, from: JSONSerialization.data(withJSONObject: capabilities)
        )
        guard let descriptor = discovery.shepherd_guarded_input, descriptor.protocol_version == 1,
              descriptor.state == "qualified", descriptor.agents.contains("claude") else { return nil }
        let inspection = try client.sendV2(method: "surface.shepherd.inspect", params: [
            "workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString
        ], responseTimeout: 1)
        guard let host = try ShepherdHookLaunchReceipt.captureHost(
            inspection: JSONSerialization.data(withJSONObject: inspection),
            workspaceID: workspaceID, surfaceID: surfaceID
        ) else {
            throw CLIError(message: "Shepherd host inspection did not retain the exact launch target.")
        }
        return host
    }

    private struct ShepherdDiscovery: Decodable {
        let shepherd_guarded_input: ShepherdDescriptor?
    }

    private struct ShepherdDescriptor: Decodable {
        let protocol_version: Int
        let state: String
        let agents: [String]
    }

    private func readPrivateShepherdSettings(path: String) throws -> Data {
        guard let data = try ShepherdHookReadinessProof.loadStoreData(
            environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": path]
        ), data.count <= 1024 * 1024 else {
            throw CLIError(message: "Shepherd launch settings are missing or exceed their artifact limit.")
        }
        return data
    }

    private func writePrivateShepherdSettings(_ data: Data, beside path: String) throws -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CLIError(message: "Shepherd guarded settings require the wrapper's private artifact directory.")
        }
        let target = directory.appendingPathComponent("shepherd-\(Self.shepherdDigest(data)).json")
        if lstat(target.path, &info) == 0 {
            guard try readPrivateShepherdSettings(path: target.path) == data else {
                throw CLIError(message: "Shepherd guarded settings do not match their existing content-addressed artifact.")
            }
            return target.path
        }
        guard errno == ENOENT else {
            throw CLIError(message: "Shepherd guarded settings artifact could not be inspected.")
        }
        let temporary = directory.appendingPathComponent(".shepherd-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: target)
        guard try readPrivateShepherdSettings(path: target.path) == data else {
            throw CLIError(message: "Shepherd guarded settings changed before launch.")
        }
        return target.path
    }

    private static func shepherdDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
