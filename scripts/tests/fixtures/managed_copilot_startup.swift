import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

@MainActor
enum ManagedCopilotStartupFixture {
    static func run(_ scenario: String) async throws -> [String: Any] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let nonce = UUID()
        let process = try AgentSessionOwnedProcessLauncher(supervisorExecutableURL: executable).prepareManaged(
            nonce: nonce, executableURL: executable, arguments: ["--fixture-copilot-peer", scenario],
            workingDirectory: "/tmp", environment: [:]
        )
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let lifetime = try AgentSessionManagedSession(
            nonce: nonce, hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
            surfaceGeneration: 1, provider: .copilot,
            executableURL: executable,
            executableIdentity: ShepherdHookExecutableIdentity.capture(path: executable.path),
            executableSHA256: String(repeating: "a", count: 64),
            profileSHA256: String(repeating: "b", count: 64), workingDirectory: "/tmp",
            stdout: output.fileHandleForReading, stderr: error.fileHandleForReading
        )
        let adapter = try CopilotManagedSession(
            lifetime: lifetime, takingOwnershipOf: input.fileHandleForWriting, workingDirectory: "/tmp"
        )
        try process.run()
        defer {
            try? lifetime.abandon()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        guard let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) else {
            throw POSIXError(.ESRCH)
        }
        try lifetime.attach(supervisor: supervisor)
        try await ManagedSessionLifetimeFixture.wait { lifetime.phase == .awaitingProvider }
        if scenario == "dead-before-start" {
            guard let backend = lifetime.backendIdentity, kill(backend.pid, SIGKILL) == 0 else {
                throw POSIXError(.ESRCH)
            }
            try await ManagedSessionLifetimeFixture.wait { lifetime.phase == .held }
        }
        if scenario == "kernel-dead-before-start" {
            guard let backend = lifetime.backendIdentity,
                  kill(process.processIdentifier, SIGSTOP) == 0 else { throw POSIXError(.ESRCH) }
            defer { kill(process.processIdentifier, SIGCONT) }
            guard kill(backend.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while AgentPIDProcessIdentity.processSnapshot(pid: backend.pid) != nil {
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                usleep(1_000)
            }
        }
        let beforeStart = ManagedSessionLifetimeFixture.phase(lifetime)
        adapter.start(launchID: scenario == "stale-start" ? UUID() : lifetime.launchID)
        if scenario == "stale-start" {
            try await Task.sleep(for: .milliseconds(100))
        } else {
            let deadline = ContinuousClock.now.advanced(by: .seconds(scenario == "timeout" ? 7 : 2))
            while adapter.phase != .held && adapter.phase.rawValue != "configurationObserved"
                    && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            // A duplicate response must still invalidate a completed startup.
            try await Task.sleep(for: .milliseconds(80))
        }
        return [
            "phase": adapter.phase.rawValue, "reason": adapter.holdReason ?? "",
            "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
            "sessionID": adapter.sessionID,
            "boundSessionID": lifetime.identity?.providerSessionID ?? "",
            "bufferedEvents": adapter.bufferedEvents.count,
            "nativeBeforeStart": beforeStart,
        ]
    }

    static func peer(_ scenario: String) throws {
        var framer = ShepherdManagedRPCFramer()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var plannedID: String?
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            for body in try framer.append(Data(bytes.prefix(count))) {
                guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      request["jsonrpc"] as? String == "2.0",
                      let id = request["id"] as? String,
                      let method = request["method"] as? String,
                      let params = request["params"] as? [String: Any] else {
                    throw POSIXError(.EPROTO)
                }
                if scenario == "timeout" { continue }
                if scenario == "unknown-id" {
                    try send(["jsonrpc": "2.0", "id": "foreign", "result": [:]])
                    continue
                }
                if scenario == "server-request" {
                    try send(["jsonrpc": "2.0", "id": "server", "method": "tool.call", "params": [:]])
                    continue
                }
                if scenario == "error" {
                    try send(["jsonrpc": "2.0", "id": id,
                              "error": ["code": -32601, "message": "unsupported"]])
                    continue
                }
                if scenario == "ambiguous-response" {
                    try send(["jsonrpc": "2.0", "id": id, "result": [:],
                              "error": ["code": -32603, "message": "ambiguous"]])
                    continue
                }
                if scenario == "missing-result" {
                    try send(["jsonrpc": "2.0", "id": id])
                    continue
                }
                let result: [String: Any]
                switch method {
                case "connect":
                    guard params["supportedTaskKinds"] as? [String] == ["agent", "client", "shell"] else {
                        throw POSIXError(.EPROTO)
                    }
                    result = [
                        "ok": scenario == "not-ok" ? false : true,
                        "protocolVersion": scenario == "wrong-protocol" ? 2 : 3,
                        "version": scenario == "wrong-version" ? "1.0.97" : "1.0.98",
                    ]
                case "session.create":
                    if scenario == "strict-profile" {
                        let disabled = [
                            "enableSessionTelemetry", "enableOnDemandInstructionDiscovery",
                            "enableHostGitOperations", "enableSessionStore", "enableGitHubCacheStore",
                            "isExperimentalMode",
                        ]
                        guard disabled.allSatisfy({ params[$0] as? Bool == false }),
                              params["skipEmbeddingRetrieval"] as? Bool == true,
                              params["mcpOAuthTokenStorage"] as? String == "in-memory",
                              params["embeddingCacheStorage"] as? String == "in-memory",
                              params["memory"] as? [String: Bool] == ["enabled": false],
                              params["infiniteSessions"] as? [String: Bool] == ["enabled": false],
                              params["toolFilterPrecedence"] as? String == "excluded",
                              ["additionalDirectories", "skillDirectories", "agentDirectories",
                               "instructionDirectories", "hookDirectories", "pluginDirectories"]
                                .allSatisfy({ params[$0] as? [String] == [] }),
                              let systemMessage = params["systemMessage"] as? [String: Any],
                              systemMessage["mode"] as? String == "customize",
                              systemMessage["sections"] as? [String: [String: String]]
                                == ["environment_context": ["action": "remove"]] else {
                            throw POSIXError(.EPROTO)
                        }
                    }
                    guard let sid = params["sessionId"] as? String,
                          UUID(uuidString: sid) != nil,
                          params["workingDirectory"] as? String == "/tmp",
                          params["enableConfigDiscovery"] as? Bool == false,
                          params["enableSkills"] as? Bool == false,
                          params["enableFileHooks"] as? Bool == false,
                          params["availableTools"] as? [String] == [],
                          params["mcpServers"] as? [String: String] == [:],
                          params["customAgents"] as? [String] == [],
                          params["requestPermission"] as? Bool == true,
                          params["streaming"] as? Bool == true else {
                        throw POSIXError(.EPROTO)
                    }
                    plannedID = sid
                    if scenario != "missing-start" {
                        var data: [String: Any] = [
                            "copilotVersion": "1.0.98", "producer": "copilot-agent",
                            "sessionId": sid, "startTime": "2026-10-19T13:00:00.000Z", "version": 1,
                            "alreadyInUse": false, "remoteSteerable": false,
                        ]
                        if scenario == "bad-start-data" { data.removeValue(forKey: "version") }
                        if scenario == "boolean-start-version" { data["version"] = true }
                        if scenario == "foreign-start-data" { data["sessionId"] = "foreign" }
                        if scenario == "already-in-use" { data["alreadyInUse"] = true }
                        if scenario == "remote-steerable" { data["remoteSteerable"] = true }
                        if scenario == "detached-start" { data["detachedFromSpawningParentSessionId"] = "foreign" }
                        var event: [String: Any] = [
                            "id": UUID().uuidString, "type": "session.start", "data": data,
                            "parentId": NSNull(), "timestamp": "2026-10-19T13:00:00.000Z",
                        ]
                        if scenario == "bad-start-shape" { event.removeValue(forKey: "timestamp") }
                        if scenario == "invalid-start-id" { event["id"] = "" }
                        if scenario == "subagent-start" { event["agentId"] = "child" }
                        let notification: [String: Any] = [
                            "jsonrpc": "2.0", "method": "session.event",
                            "params": ["sessionId": scenario == "foreign-event" ? "foreign" : sid,
                                       "event": event],
                        ]
                        try send(notification)
                        if scenario == "duplicate-start" { try send(notification) }
                    }
                    result = ["sessionId": scenario == "wrong-session" ? "foreign" : sid]
                case "session.options.update":
                    if scenario == "strict-profile" {
                        guard params["includedBuiltinAgents"] as? [String] == [],
                              params["sessionCapabilities"] as? [String] == [],
                              params["continueOnAutoMode"] as? Bool == false else {
                            throw POSIXError(.EPROTO)
                        }
                    }
                    guard params["sessionId"] as? String == plannedID,
                          params["skipCustomInstructions"] as? Bool == true,
                          params["customAgentsLocalOnly"] as? Bool == true,
                          params["coauthorEnabled"] as? Bool == false,
                          params["manageScheduleEnabled"] as? Bool == false,
                          params["installedPlugins"] as? [String] == [],
                          params["includedBuiltinSkills"] as? [String] == [] else {
                        throw POSIXError(.EPROTO)
                    }
                    result = ["success": scenario != "options-refused", "pluginHookCount": 0]
                case "session.agent.list":
                    guard params["includeBuiltInAgents"] as? Bool == true else { throw POSIXError(.EPROTO) }
                    result = ["agents": scenario == "inherited-agent" ? [["name": "unexpected"]] : []]
                case "session.agent.getCurrent":
                    result = scenario == "missing-current-agent" ? [:] : [
                        "agent": scenario == "selected-agent" ? ["name": "unexpected"] : NSNull(),
                    ]
                case "session.mcp.listConfigured":
                    result = ["servers": scenario == "inherited-mcp" ? [["name": "unexpected"]] : []]
                case "session.plugins.list":
                    result = ["plugins": scenario == "managed-plugin" ? [["name": "unexpected"]] : []]
                case "session.extensions.list":
                    result = ["extensions": scenario == "inherited-extension" ? [["name": "unexpected"]] : []]
                case "session.tools.initializeAndValidate":
                    result = [:]
                case "session.tools.getCurrentMetadata":
                    result = ["tools": scenario == "null-tools" ? NSNull()
                              : scenario == "unaccounted-tool" ? [["name": "unexpected"]] : []]
                default:
                    throw POSIXError(.EPROTO)
                }
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                try send(response)
                if scenario == "duplicate" { try send(response) }
            }
        }
    }

    static func send(_ value: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let frame = try ShepherdManagedRPCFramer.frame(body)
        // Exercise real incremental input rather than assuming one read per frame.
        for offset in stride(from: 0, to: frame.count, by: 7) {
            try FileHandle.standardOutput.write(contentsOf: frame.subdata(in: offset..<min(frame.count, offset + 7)))
        }
    }
}
