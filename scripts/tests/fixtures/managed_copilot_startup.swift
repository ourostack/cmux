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
        adapter.start(launchID: scenario == "stale-start" ? UUID() : lifetime.launchID)
        if scenario == "stale-start" {
            try await Task.sleep(for: .milliseconds(100))
        } else {
            try await ManagedSessionLifetimeFixture.wait({
                adapter.phase == .held || adapter.phase == .awaitingReadback
            }, seconds: 8)
            // A duplicate response must still invalidate a completed startup.
            try await Task.sleep(for: .milliseconds(80))
        }
        return [
            "phase": adapter.phase.rawValue, "reason": adapter.holdReason ?? "",
            "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
            "sessionID": adapter.sessionID,
            "boundSessionID": lifetime.identity?.providerSessionID ?? "",
            "bufferedEvents": adapter.bufferedEvents.count,
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
                    if scenario == "early-event" || scenario == "foreign-event" {
                        try send([
                            "jsonrpc": "2.0", "method": "session.event",
                            "params": ["sessionId": scenario == "foreign-event" ? "foreign" : sid,
                                       "event": ["id": UUID().uuidString, "type": "session.start", "data": [:]]],
                        ])
                    }
                    result = ["sessionId": scenario == "wrong-session" ? "foreign" : sid]
                case "session.options.update":
                    guard params["sessionId"] as? String == plannedID,
                          params["skipCustomInstructions"] as? Bool == true,
                          params["customAgentsLocalOnly"] as? Bool == true,
                          params["coauthorEnabled"] as? Bool == false,
                          params["manageScheduleEnabled"] as? Bool == false,
                          params["installedPlugins"] as? [String] == [],
                          params["includedBuiltinSkills"] as? [String] == [] else {
                        throw POSIXError(.EPROTO)
                    }
                    result = [:]
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
