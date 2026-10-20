import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

@MainActor
enum ManagedCopilotStartupFixture {
    static func run(_ scenario: String) async throws -> [String: Any] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copilot-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let callbackFile = directory.appendingPathComponent("document.txt")
        if scenario.hasPrefix("owner-tool-") {
            try Data("before\n".utf8).write(to: callbackFile)
        }
        try JSONSerialization.data(withJSONObject: ["scenario": scenario, "callbackFile": callbackFile.path])
            .write(to: directory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        var candidate = executable
        if scenario == "launch-replaced-before-start" {
            candidate = directory.appendingPathComponent("candidate")
            try FileManager.default.copyItem(at: executable, to: candidate)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        }
        let launch = try await AgentSessionManagedCopilotLaunch.prepare(
            scope: .init(hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(), generation: 1),
            executableURL: candidate, workingDirectory: directory.path,
            codingProjectMandate: scenario.hasPrefix("owner-tool-") && scenario != "owner-tool-no-native-authority" ? UUID() : nil,
            launcher: AgentSessionOwnedProcessLauncher(supervisorExecutableURL: executable)
        )
        do {
            if scenario == "launch-replaced-before-start" {
                try FileManager.default.moveItem(at: candidate, to: directory.appendingPathComponent("old"))
                try FileManager.default.copyItem(at: executable, to: candidate)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
                var rejected = false
                do { try launch.launchBackend() } catch { rejected = true }
                try await launch.close()
                return [
                    "rejected": rejected,
                    "peerStarted": FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(".cmux-controlled-copilot-trace").path
                    ),
                ]
            }
            var result = try await exercise(scenario, launch: launch, callbackFile: callbackFile)
            if scenario == "launch-supervisor-killed" { return result }
            if scenario == "owner-tool-revoked" {
                do {
                    try await launch.close()
                    result["cleanupVerified"] = true
                } catch AgentSessionManagedCopilotLaunch.CloseError.commandWorkUnsettled(let outstanding) {
                    result["cleanupVerified"] = false
                    result["cleanupError"] = "commandWorkUnsettled"
                    result["cleanupOutstandingCommandWork"] = outstanding
                }
                return result
            }
            try await launch.close()
            return result
        } catch {
            let original = error
            try await launch.close()
            throw original
        }
    }

    static func exercise(
        _ scenario: String, launch: AgentSessionManagedCopilotLaunch, callbackFile: URL
    ) async throws -> [String: Any] {
        let lifetime = launch.lifetime, adapter = launch.adapter, authority = launch.codingAuthority
        try launch.launchBackend()
        try await ManagedSessionLifetimeFixture.wait { lifetime.phase == .awaitingProvider }
        if scenario == "launch-supervisor-killed" {
            guard let backend = lifetime.backendIdentity else { throw POSIXError(.ESRCH) }
            defer {
                if AgentPIDProcessIdentity(pid: backend.pid) == backend { _ = kill(backend.pid, SIGKILL) }
            }
            let supervisorPID = launch.processIdentifier
            guard kill(supervisorPID, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            try await ManagedSessionLifetimeFixture.wait { AgentPIDProcessIdentity(pid: supervisorPID) == nil }
            var firstCloseError = ""
            do { try await launch.close() } catch { firstCloseError = String(describing: error) }
            let backendStillAlive = AgentPIDProcessIdentity(pid: backend.pid) == backend
            var secondCloseError = ""
            do { try await launch.close() } catch { secondCloseError = String(describing: error) }
            if AgentPIDProcessIdentity(pid: backend.pid) == backend {
                guard kill(backend.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            }
            try await ManagedSessionLifetimeFixture.wait { AgentPIDProcessIdentity(pid: backend.pid) != backend }
            return [
                "backendStillAlive": backendStillAlive, "closeFailed": !firstCloseError.isEmpty,
                "secondCloseFailed": !secondCloseError.isEmpty, "sameCloseError": firstCloseError == secondCloseError,
                "firstCloseError": firstCloseError, "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
                "fixtureBackendAbsent": true,
            ]
        }
        if scenario == "launch-duplicate-start" {
            var rejected = false
            do { try launch.launchBackend() } catch { rejected = true }
            return ["rejected": rejected, "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
                    "workEvidence": adapter.hasCompleteWorkEvidence]
        }
        if scenario == "dead-before-start" {
            guard let backend = lifetime.backendIdentity, kill(backend.pid, SIGKILL) == 0 else {
                throw POSIXError(.ESRCH)
            }
            try await ManagedSessionLifetimeFixture.wait { lifetime.phase == .held }
        }
        if scenario == "kernel-dead-before-start" {
            guard let backend = lifetime.backendIdentity,
                  kill(launch.processIdentifier, SIGSTOP) == 0 else { throw POSIXError(.ESRCH) }
            defer { kill(launch.processIdentifier, SIGCONT) }
            guard kill(backend.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while AgentPIDProcessIdentity.processSnapshot(pid: backend.pid) != nil {
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                usleep(1_000)
            }
        }
        let beforeStart = ManagedSessionLifetimeFixture.phase(lifetime)
        let hostInputID = UUID()
        let nextHostInputID = UUID()
        var inputAccepted = false
        var secondAccepted = false
        var nextAccepted = false
        if scenario == "owner-before-start" {
            inputAccepted = adapter.submitOwnerInput(hostInputID, prompt: "Owner input: 雪 🐈", launchID: lifetime.launchID)
        }
        adapter.start(launchID: scenario == "stale-start" ? UUID() : lifetime.launchID)
        if scenario == "stale-start" {
            try await Task.sleep(for: .milliseconds(100))
        } else {
            while adapter.phase != .held && adapter.phase.rawValue != "configurationObserved" {
                try await Task.sleep(for: .milliseconds(5))
            }
            // A duplicate response must still invalidate a completed startup.
            try await Task.sleep(for: .milliseconds(80))
        }
        if ["owner-tool-close-queued-input", "owner-close-queued-input"].contains(scenario) {
            let queued = Task(priority: .high) { @MainActor in
                adapter.submitOwnerInput(hostInputID, prompt: "Owner input: 雪 🐈", launchID: lifetime.launchID)
            }
            try await launch.close()
            let accepted = await queued.value
            let traceFile = URL(fileURLWithPath: launch.workingDirectory)
                .appendingPathComponent(".cmux-controlled-copilot-trace")
            let trace = FileManager.default.fileExists(atPath: traceFile.path)
                ? try String(contentsOf: traceFile, encoding: .utf8) : ""
            return [
                "queuedInputAccepted": accepted, "wireSendObserved": trace.split(separator: "\n").contains("session.send"),
                "workEvidence": adapter.hasCompleteWorkEvidence, "phase": adapter.phase.rawValue,
            ]
        }
        if scenario.hasPrefix("owner-") && scenario != "owner-before-start" {
            inputAccepted = adapter.submitOwnerInput(
                hostInputID, prompt: scenario == "owner-whitespace" ? " \n\t" : "Owner input: 雪 🐈",
                launchID: scenario == "owner-stale-launch" ? UUID() : lifetime.launchID
            )
            if scenario != "owner-stale-launch" && scenario != "owner-whitespace" {
                secondAccepted = adapter.submitOwnerInput(UUID(), prompt: "must not queue", launchID: lifetime.launchID)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(scenario.hasPrefix("owner-tool-") ? 8 : 2))
            while adapter.phase != .held && !adapter.hasCompleteWorkEvidence && ContinuousClock.now < deadline {
                if scenario == "owner-tool-revoked", adapter.phase == .executingCallback,
                   authority?.outstandingWorkCount == 1 { authority?.revoke() }
                try await Task.sleep(for: .milliseconds(5))
            }
            if ["owner-next-input", "owner-reused-host", "owner-reused-provider", "owner-late-prior-root"]
                .contains(scenario), adapter.hasCompleteWorkEvidence {
                nextAccepted = adapter.submitOwnerInput(
                    scenario == "owner-reused-host" ? hostInputID : nextHostInputID,
                    prompt: "Owner input: 雪 🐈", launchID: lifetime.launchID
                )
                let nextDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while adapter.phase != .held && !adapter.hasCompleteWorkEvidence
                        && ContinuousClock.now < nextDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        if adapter.phase == .held { await adapter.waitForCommandSettlement() }
        let executionFile = URL(fileURLWithPath: callbackFile.path + ".executions")
        let traceFile = URL(fileURLWithPath: launch.workingDirectory).appendingPathComponent(".cmux-controlled-copilot-trace")
        return [
            "phase": adapter.phase.rawValue, "reason": adapter.holdReason ?? "",
            "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
            "nativeHold": lifetime.holdReason.map { "\($0)" } ?? "",
            "diagnostics": String(decoding: adapter.diagnostics, as: UTF8.self),
            "sessionID": adapter.sessionID,
            "boundSessionID": lifetime.identity?.providerSessionID ?? "",
            "bufferedEvents": adapter.bufferedEvents.count,
            "nativeBeforeStart": beforeStart,
            "inputAccepted": inputAccepted, "secondAccepted": secondAccepted,
            "workEvidence": adapter.hasCompleteWorkEvidence,
            "ackMatchesHost": adapter.inputState?.inputID(matchingProviderInputID: "server-input-one") == hostInputID,
            "nextAccepted": nextAccepted,
            "nextAckMatchesHost": adapter.inputState?.inputID(matchingProviderInputID: "server-input-two") == nextHostInputID,
            "callbackFile": scenario.hasPrefix("owner-tool-")
                ? String(decoding: try Data(contentsOf: callbackFile), as: UTF8.self) : "",
            "callbackExecutions": FileManager.default.fileExists(atPath: executionFile.path)
                ? String(decoding: try Data(contentsOf: executionFile), as: UTF8.self) : "",
            "nativeOutstanding": authority?.outstandingWorkCount ?? 0,
            "outstandingActivities": adapter.inputState?.outstandingActivityCount ?? 0,
            "executableSHA256": lifetime.identity?.executableSHA256 ?? "",
            "profileSHA256": lifetime.identity?.profileSHA256 ?? "",
            "profileManifest": String(decoding: launch.profileManifest, as: UTF8.self),
            "backendArguments": launch.backendArguments,
            "peerTrace": FileManager.default.fileExists(atPath: traceFile.path)
                ? try String(contentsOf: traceFile, encoding: .utf8) : "",
        ]
    }

    static func peer(_ scenario: String) throws {
        try recordTrace("peer-started")
        if scenario == "launch-supervisor-killed" {
            while true { usleep(10_000) }
        }
        let directory = FileManager.default.currentDirectoryPath
        var framer = ShepherdManagedRPCFramer()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var plannedID: String?
        var requestedNoBuiltinAgents = false
        var sentInputs = 0
        var workStep = 0
        var initializedTools = false
        var readbackStep = 0
        var configurationEventID: String?
        var callbackStep = 0
        var nativeToolAdvertised = false
        var interruptedAutomaticFrame = false
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 {
                try recordTrace("stdinEOF")
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            let bodies = try framer.append(Data(bytes.prefix(count)))
            if scenario == "owner-tool-native-supervisor-backpressure",
               sentInputs == 1, workStep == 4, !interruptedAutomaticFrame {
                guard bodies.isEmpty, let plannedID else { throw POSIXError(.EPROTO) }
                interruptedAutomaticFrame = true
                try recordTrace("partial-supervisor-chunk:\(count)")
                try sendEvent(sessionID: plannedID, type: "assistant.intent",
                              data: ["intent": "New activity while input is partially admitted"])
                usleep(100_000)
            }
            for body in bodies {
                guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      request["jsonrpc"] as? String == "2.0",
                      let id = request["id"] as? String,
                      let method = request["method"] as? String,
                      let params = request["params"] as? [String: Any] else {
                    throw POSIXError(.EPROTO)
                }
                try recordTrace(method)
                try recordTrace("request-read:\(method) at \(Date().timeIntervalSince1970)")
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
                if scenario == "configuration-readback-order" {
                    let ordered = [
                        "session.tools.initializeAndValidate", "session.agent.list", "session.agent.getCurrent",
                        "session.mcp.listConfigured", "session.plugins.list", "session.extensions.list",
                        "session.tools.getCurrentMetadata",
                    ]
                    if ordered.contains(method) {
                        guard readbackStep < ordered.count, method == ordered[readbackStep] else {
                            throw POSIXError(.EPROTO)
                        }
                        readbackStep += 1
                    }
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
                    try recordTrace("createDirectory=\(String(describing: params["workingDirectory"])); peerDirectory=\(directory)")
                    if scenario.hasPrefix("owner-tool-") {
                        let tools = params["tools"] as? [[String: Any]] ?? []
                        nativeToolAdvertised = tools.count == 1
                            && tools.first?["name"] as? String == "cmux_run_foreground"
                        if !tools.isEmpty {
                            let expected: [String: Any] = [
                                "name": "cmux_run_foreground",
                                "description": "Run one foreground command with the native project authority. No terminal, background work, stdin, directory, environment or timeout overrides.",
                                "parameters": [
                                    "type": "object", "properties": [
                                        "program": ["type": "string"], "arguments": ["type": "array", "items": ["type": "string"]],
                                    ],
                                    "required": ["program", "arguments"], "additionalProperties": false,
                                ],
                                "isTerminal": false, "overridesBuiltInTool": false, "skipPermission": true,
                            ]
                            guard tools.count == 1,
                                  try JSONSerialization.data(withJSONObject: tools[0], options: [.sortedKeys])
                                    == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]) else {
                                throw POSIXError(.EPROTO)
                            }
                        }
                    }
                    if scenario == "strict-profile" || scenario.hasPrefix("owner-tool-") {
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
                          params["workingDirectory"] as? String == directory,
                          params["enableConfigDiscovery"] as? Bool == false,
                          params["enableSkills"] as? Bool == false,
                          params["enableFileHooks"] as? Bool == false,
                          (params["availableTools"] as? [String] == []
                           || (scenario.hasPrefix("owner-tool-")
                               && params["availableTools"] as? [String] == ["custom:cmux_run_foreground"])),
                          params["mcpServers"] as? [String: String] == [:],
                          params["customAgents"] as? [String] == [],
                          params["requestPermission"] as? Bool == true,
                          params["streaming"] as? Bool == true else {
                        throw POSIXError(.EPROTO)
                    }
                    plannedID = sid
                    if scenario == "configuration-before-start" || scenario == "configuration-without-start"
                        || scenario == "owner-configuration-replay" {
                        let eventID = UUID().uuidString
                        configurationEventID = eventID
                        try sendConfiguration("configuration-before-start", sessionID: sid, firstID: eventID)
                    }
                    if scenario != "missing-start" && scenario != "configuration-without-start" {
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
                        if [
                            "configuration-at-create", "configuration-duplicate", "configuration-start-replay",
                            "configuration-limit", "configuration-overflow",
                        ].contains(scenario) || scenario.hasPrefix("configuration-nonempty-")
                            || scenario.hasPrefix("configuration-malformed-")
                            || scenario.hasPrefix("configuration-foreign-") {
                            try sendConfiguration(
                                scenario, sessionID: sid,
                                firstID: scenario == "configuration-start-replay" ? event["id"] as? String : nil
                            )
                        }
                    }
                    result = ["sessionId": scenario == "wrong-session" ? "foreign" : sid]
                case "session.options.update":
                    if scenario == "strict-profile" || scenario.hasPrefix("owner-tool-") {
                        guard params["includedBuiltinAgents"] as? [String] == [],
                              params["sessionCapabilities"] as? [String] == [],
                              params["continueOnAutoMode"] as? Bool == false,
                              params["availableTools"] as? [String] == (nativeToolAdvertised ? ["custom:cmux_run_foreground"] : []),
                              params["excludedTools"] as? [String] == [],
                              params["toolFilterPrecedence"] as? String == "excluded" else {
                            throw POSIXError(.EPROTO)
                        }
                    }
                    guard params["sessionId"] as? String == plannedID,
                          params["includedBuiltinAgents"] as? [String] == [],
                          params["skipCustomInstructions"] as? Bool == true,
                          params["customAgentsLocalOnly"] as? Bool == true,
                          params["coauthorEnabled"] as? Bool == false,
                          params["manageScheduleEnabled"] as? Bool == false,
                          params["installedPlugins"] as? [String] == [],
                          params["includedBuiltinSkills"] as? [String] == [] else {
                        throw POSIXError(.EPROTO)
                    }
                    requestedNoBuiltinAgents = true
                    if scenario == "configuration-at-options" {
                        try sendConfiguration(scenario, sessionID: plannedID!)
                    }
                    result = ["success": scenario != "options-refused", "pluginHookCount": 0]
                case "session.agent.list":
                    guard params["includeBuiltInAgents"] as? Bool == true, requestedNoBuiltinAgents else {
                        throw POSIXError(.EPROTO)
                    }
                    if scenario == "configuration-during-readback" {
                        try sendConfiguration("configuration-before-start", sessionID: plannedID!)
                    }
                    result = ["agents": scenario == "inherited-agent"
                              || (scenario == "configuration-stale-readback" && initializedTools)
                              ? [["name": "unexpected"]] : []]
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
                    initializedTools = true
                    if scenario == "configuration-at-initialize" || scenario == "configuration-stale-readback" {
                        try sendConfiguration(scenario, sessionID: plannedID!)
                    }
                    result = [:]
                case "session.tools.getCurrentMetadata":
                    if nativeToolAdvertised {
                        var metadata: [String: Any] = [
                            "name": "cmux_run_foreground",
                            "description": "Run one foreground command with the native project authority. No terminal, background work, stdin, directory, environment or timeout overrides.",
                            "input_schema": [
                                "type": "object", "properties": [
                                    "program": ["type": "string"], "arguments": ["type": "array", "items": ["type": "string"]],
                                ],
                                "required": ["program", "arguments"], "additionalProperties": false,
                            ],
                        ]
                        if scenario == "owner-tool-metadata-extra" { metadata["namespacedName"] = "custom:cmux_run_foreground" }
                        if scenario == "owner-tool-metadata-deferred" { metadata["deferLoading"] = true }
                        if scenario == "owner-tool-metadata-mcp" { metadata["mcpServerName"] = "foreign" }
                        result = ["tools": [metadata]]
                    } else {
                        result = ["tools": scenario == "null-tools" ? NSNull()
                                  : scenario == "unaccounted-tool" ? [["name": "unexpected"]] : []]
                    }
                case "session.send":
                    guard scenario.hasPrefix("owner-"), sentInputs == 0 || (
                            sentInputs == 1 && ["owner-next-input", "owner-reused-provider", "owner-late-prior-root",
                                               "owner-tool-native-supervisor", "owner-tool-native-supervisor-missing-ack",
                                               "owner-tool-native-supervisor-backpressure"]
                                .contains(scenario)
                          ),
                          Set(params.keys) == ["sessionId", "prompt", "source", "agentMode", "mode"],
                          params["sessionId"] as? String == plannedID,
                          params["prompt"] as? String == (
                            scenario == "owner-tool-native-supervisor-backpressure" && sentInputs == 1
                                ? String(repeating: "x", count: 128 * 1024)
                                : scenario.hasPrefix("owner-tool-native-supervisor") && sentInputs == 1
                                ? "Continue authorized coding." : "Owner input: 雪 🐈"
                          ),
                          params["source"] as? String == "user",
                          params["agentMode"] as? String == "interactive",
                          params["mode"] as? String == "enqueue",
                          let plannedID else { throw POSIXError(.EPROTO) }
                    sentInputs += 1
                    workStep = 0
                    if scenario == "owner-tool-native-supervisor-missing-ack", sentInputs == 2 { continue }
                    if scenario == "owner-tool-before-send-ack" {
                        try sendTool(sessionID: plannedID, step: callbackStep, scenario: scenario)
                        usleep(40_000)
                        guard let file = try configuration()["callbackFile"],
                              !FileManager.default.fileExists(atPath: file + ".executions") else {
                            throw POSIXError(.EPROTO)
                        }
                    }
                    if scenario == "owner-early-root" { try sendRoot(sessionID: plannedID, scenario: scenario) }
                    var ack: [String: Any] = ["messageId": "server-input-one"]
                    if sentInputs == 2 && scenario != "owner-reused-provider" {
                        ack["messageId"] = "server-input-two"
                    }
                    if scenario == "owner-missing-ack-id" { ack = [:] }
                    if scenario == "owner-empty-ack-id" { ack["messageId"] = "" }
                    if scenario == "owner-null-ack-id" { ack["messageId"] = NSNull() }
                    let response: [String: Any] = [
                        "jsonrpc": "2.0", "id": scenario == "owner-foreign-ack" ? "foreign" : id, "result": ack,
                    ]
                    try send(response)
                    try recordTrace("response-written:\(method) at \(Date().timeIntervalSince1970)")
                    if scenario == "owner-duplicate-ack" { try send(response) }
                    if scenario == "owner-configuration-changed" {
                        try sendConfiguration("configuration-before-start", sessionID: plannedID)
                    }
                    if scenario.hasPrefix("owner-tool-native-supervisor"), sentInputs == 2 {
                        try sendRoot(sessionID: plannedID, scenario: scenario, input: 2)
                    } else if scenario.hasPrefix("owner-tool-") {
                        if scenario != "owner-tool-before-send-ack" {
                            try sendTool(sessionID: plannedID, step: callbackStep, scenario: scenario)
                        }
                        if scenario == "owner-tool-unrequested-permission" {
                            try send(["jsonrpc": "2.0", "id": "server-permission",
                                      "method": "permission.request", "params": ["sessionId": plannedID]])
                        }
                    } else if scenario != "owner-early-root" && scenario != "owner-ack-only" {
                        try sendRoot(
                            sessionID: plannedID, scenario: scenario,
                            input: scenario == "owner-late-prior-root" ? 1 : sentInputs,
                            replayEventID: scenario == "owner-configuration-replay" ? configurationEventID : nil
                        )
                    }
                    continue
                case "session.tools.handlePendingToolCall":
                    guard scenario.hasPrefix("owner-tool-"), callbackStep < 3,
                          Set(params.keys) == ["sessionId", "requestId", "result"],
                          params["sessionId"] as? String == plannedID,
                          params["requestId"] as? String == "request-\(callbackStep)",
                          let toolResult = params["result"] as? [String: Any],
                          Set(toolResult.keys) == ["textResultForLlm", "resultType"],
                          toolResult["resultType"] as? String == (scenario == "owner-tool-known-failure" ? "failure" : "success"),
                          let text = toolResult["textResultForLlm"] as? String,
                          let encoded = text.data(using: .utf8),
                          let report = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                          report["status"] as? Int == (scenario == "owner-tool-known-failure" ? 7 : 0),
                          report["stdout"] as? String == (scenario == "owner-tool-invalid-utf8" ? "\u{fffd}"
                              : scenario == "owner-tool-large-result"
                              ? String(repeating: "\u{1}", count: 16 * 1024) : callbackStep == 0 ? "before\n"
                              : callbackStep == 1 ? "" : "validated\n"),
                          report["stderr"] as? String == (scenario == "owner-tool-large-result"
                              ? String(repeating: "\u{2}", count: 16 * 1024)
                              : scenario == "owner-tool-known-failure" ? "known failure\n" : ""),
                          report["stdoutTruncated"] as? Bool == (scenario == "owner-tool-large-result"),
                          report["stderrTruncated"] as? Bool == (scenario == "owner-tool-large-result"),
                          report["decoding"] as? String == "utf8-replacement",
                          report["stdoutBytes"] as? Int == (scenario == "owner-tool-invalid-utf8" ? 1
                              : scenario == "owner-tool-large-result" ? 20_000
                              : callbackStep == 0 ? 7 : callbackStep == 1 ? 0 : 10),
                          report["stderrBytes"] as? Int == (scenario == "owner-tool-large-result" ? 20_000
                              : scenario == "owner-tool-known-failure" ? 14 : 0) else {
                        throw POSIXError(.EPROTO)
                    }
                    if scenario == "owner-tool-idle-before-ack" {
                        try sendEvent(sessionID: plannedID!, type: "session.idle", data: [:])
                    }
                    if scenario == "owner-tool-root-before-ack" {
                        try sendRoot(sessionID: plannedID!, scenario: scenario)
                    }
                    if scenario == "owner-tool-ui-before-ack" {
                        try sendEvent(sessionID: plannedID!, type: "external_tool.completed",
                                      data: ["requestId": "request-\(callbackStep)"])
                    }
                    if scenario == "owner-tool-missing-ack" { continue }
                    var acknowledgement: [String: Any] = ["success": true]
                    if scenario == "owner-tool-refused-ack" { acknowledgement["success"] = false }
                    if scenario == "owner-tool-numeric-ack" { acknowledgement["success"] = 1 }
                    if scenario == "owner-tool-extra-ack" { acknowledgement["unexpected"] = true }
                    if scenario == "owner-tool-empty-ack" { acknowledgement = [:] }
                    try send([
                        "jsonrpc": "2.0", "id": scenario == "owner-tool-foreign-ack" ? "foreign" : id,
                        "result": acknowledgement,
                    ])
                    if scenario == "owner-tool-telemetry" {
                        try sendEvent(sessionID: plannedID!, type: "tool.execution_complete", data: [
                            "toolCallId": "call-\(callbackStep)", "success": true, "result": ["content": text],
                            "turnId": "tool-turn-\(callbackStep)",
                        ])
                    }
                    if scenario == "owner-tool-duplicate-ack" {
                        try send(["jsonrpc": "2.0", "id": id, "result": acknowledgement])
                    }
                    if scenario != "owner-tool-ui-before-ack" {
                        try sendEvent(sessionID: plannedID!, type: "external_tool.completed",
                                      data: ["requestId": "request-\(callbackStep)"])
                    }
                    try sendEvent(sessionID: plannedID!, type: "assistant.turn_end",
                                  data: ["turnId": "tool-turn-\(callbackStep)"])
                    callbackStep += 1
                    if ["owner-tool-known-failure", "owner-tool-large-result", "owner-tool-invalid-utf8"].contains(scenario) {
                        callbackStep = 3
                    }
                    if callbackStep < 3 {
                        try sendTool(sessionID: plannedID!, step: callbackStep, scenario: scenario)
                    } else {
                        try sendRoot(sessionID: plannedID!, scenario: scenario)
                    }
                    continue
                case "session.tasks.refresh", "session.tasks.list", "session.schedule.list",
                     "session.tools.listPendingRequests":
                    let methods = ["session.tasks.refresh", "session.tasks.list", "session.schedule.list",
                                   "session.tools.listPendingRequests"]
                    guard sentInputs > 0, workStep < methods.count, methods[workStep] == method,
                          params as? [String: String] == ["sessionId": plannedID!] else {
                        throw POSIXError(.EPROTO)
                    }
                    workStep += 1
                    if scenario == "owner-work-activity" && workStep == 2 {
                        try sendEvent(sessionID: plannedID!, type: "assistant.intent", data: ["intent": "still active"])
                    }
                    switch method {
                    case "session.tasks.refresh": result = [:]
                    case "session.tasks.list":
                        result = scenario == "owner-missing-tasks" ? [:] : [
                            "tasks": scenario == "owner-background-task" ? [["id": "background"]] : [],
                        ]
                    case "session.schedule.list":
                        result = ["entries": scenario == "owner-scheduled" ? [["id": "wakeup"]] : []]
                    default:
                        result = ["items": scenario == "owner-pending-tool" ? [["requestId": "pending"]] : []]
                    }
                default:
                    throw POSIXError(.EPROTO)
                }
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                try send(response)
                try recordTrace("response-written:\(method) at \(Date().timeIntervalSince1970)")
                if scenario == "duplicate" { try send(response) }
                if scenario == "configuration-late" && method == "session.tools.getCurrentMetadata" {
                    try sendConfiguration("configuration-before-start", sessionID: plannedID!)
                }
            }
        }
    }

    static func sendTool(sessionID: String, step: Int, scenario: String) throws {
        guard let path = try configuration()["callbackFile"] else {
            throw POSIXError(.EINVAL)
        }
        var scripts = [
            (scenario == "owner-tool-revoked" ? "sleep 1; " : "") + "printf 'read\\n' >> \"$1.executions\"; cat \"$1\"",
            "printf 'edit\\n' >> \"$1.executions\"; printf 'after\\n' > \"$1\"",
            "printf 'validate\\n' >> \"$1.executions\"; test \"$(cat \"$1\")\" = after && printf 'validated\\n'",
        ]
        if scenario == "owner-tool-known-failure" {
            scripts[0] += "; printf 'known failure\\n' >&2; exit 7"
        }
        if scenario == "owner-tool-uncertain-command" { scripts[0] = "exit 254" }
        if scenario == "owner-tool-large-result" {
            scripts[0] = "printf 'read\\n' >> \"$1.executions\"; i=0; while [ $i -lt 20000 ]; do printf '\\001'; printf '\\002' >&2; i=$((i+1)); done"
        }
        if scenario == "owner-tool-invalid-utf8" {
            scripts[0] = "printf 'read\\n' >> \"$1.executions\"; printf '\\377'"
        }
        var arguments: [String: Any] = [
            "program": "/bin/sh", "arguments": ["-c", scripts[step], "controlled-callback", path],
        ]
        if scenario == "owner-tool-invalid-arguments" { arguments["directory"] = "/tmp" }
        var rootRequest: [String: Any] = [
            "toolCallId": "call-\(step)", "name": "cmux_run_foreground", "arguments": arguments,
        ]
        if scenario == "owner-tool-hosted-caller" { rootRequest["caller"] = ["type": "code", "callerId": "hosted"] }
        if scenario == "owner-tool-mcp-root" { rootRequest["mcpServerName"] = "foreign" }
        if scenario == "owner-tool-nonfunction" { rootRequest["type"] = "custom" }
        var requested: [String: Any] = [
            "requestId": "request-\(step)", "sessionId": sessionID, "toolCallId": "call-\(step)",
            "toolName": "cmux_run_foreground", "arguments": arguments,
            "workingDirectory": FileManager.default.currentDirectoryPath,
        ]
        if scenario == "owner-tool-foreign-session" { requested["sessionId"] = "foreign" }
        if scenario == "owner-tool-foreign-call" { requested["toolCallId"] = "foreign" }
        if scenario == "owner-tool-foreign-name" { requested["toolName"] = "shell" }
        if scenario == "owner-tool-foreign-provider" { requested["providerId"] = "foreign" }
        if scenario == "owner-tool-foreign-cwd" { requested["workingDirectory"] = "/" }
        if scenario == "owner-tool-parented" { requested["parentToolCallId"] = "foreign" }
        if scenario == "owner-tool-argument-mismatch" {
            requested["arguments"] = ["program": "/bin/echo", "arguments": ["foreign"]]
        }
        if scenario == "owner-tool-replayed-call", step > 0 {
            rootRequest["toolCallId"] = "call-0"
            requested["toolCallId"] = "call-0"
        }
        if scenario == "owner-tool-replayed-request", step > 0 { requested["requestId"] = "request-0" }
        if scenario == "owner-tool-external-before-root" {
            try sendEvent(sessionID: sessionID, type: "external_tool.requested", data: requested)
            usleep(40_000)
            guard step != 0 || !FileManager.default.fileExists(atPath: path + ".executions") else {
                throw POSIXError(.EPROTO)
            }
        }
        try sendEvent(sessionID: sessionID, type: "assistant.turn_start", data: ["turnId": "tool-turn-\(step)"])
        try sendEvent(sessionID: sessionID, type: "assistant.message", data: [
            "turnId": "tool-turn-\(step)",
            "originatingMessageId": scenario == "owner-tool-foreign-root" ? "foreign" : "server-input-one",
            "messageId": "tool-message-\(step)", "content": "",
            "toolRequests": [rootRequest],
        ])
        if ["owner-tool-telemetry", "owner-tool-foreign-telemetry", "owner-tool-early-complete-telemetry"]
            .contains(scenario) {
            try sendEvent(sessionID: sessionID, type: "tool.execution_start", data: [
                "toolCallId": "call-\(step)", "toolName": "cmux_run_foreground",
                "arguments": arguments, "turnId": "tool-turn-\(step)",
            ])
            try sendEvent(sessionID: sessionID, type: "tool.execution_progress", data: [
                "toolCallId": scenario == "owner-tool-foreign-telemetry" ? "foreign" : "call-\(step)",
                "progressMessage": "Running",
            ])
            if scenario == "owner-tool-early-complete-telemetry" {
                try sendEvent(sessionID: sessionID, type: "tool.execution_complete", data: [
                    "toolCallId": "call-\(step)", "success": true,
                ])
            }
        }
        if scenario != "owner-tool-external-before-root" {
            try sendEvent(sessionID: sessionID, type: "external_tool.requested", data: requested)
        }
        if scenario == "owner-tool-overlap" {
            var overlap = requested
            overlap["requestId"] = "overlap"
            overlap["toolCallId"] = "overlap"
            try sendEvent(sessionID: sessionID, type: "external_tool.requested", data: overlap)
        }
        if scenario == "owner-tool-ui-before-result" {
            try sendEvent(sessionID: sessionID, type: "external_tool.completed", data: ["requestId": "request-\(step)"])
        }
    }

    static func configuration() throws -> [String: String] {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cmux-controlled-copilot-scenario")
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: String] else {
            throw POSIXError(.EPROTO)
        }
        return value
    }

    static func recordTrace(_ value: String) throws {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cmux-controlled-copilot-trace")
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        let line = Data((value + "\n").utf8)
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(.EIO) }
        guard metadata.st_size + Int64(line.count) < 8192 else { throw POSIXError(.EOVERFLOW) }
        let count = line.withUnsafeBytes { bytes in
            var count: Int
            repeat { count = Darwin.write(descriptor, bytes.baseAddress, bytes.count) }
            while count < 0 && errno == EINTR
            return count
        }
        guard count == line.count else { throw POSIXError(.EIO) }
    }

    static func sendRoot(sessionID: String, scenario: String, input: Int = 1, replayEventID: String? = nil) throws {
        let suffix = input == 1 ? "one" : "two"
        for (type, data) in [
            ("assistant.turn_start", ["turnId": "turn-\(suffix)"] as [String: Any]),
            ("assistant.message", ["turnId": "turn-\(suffix)", "originatingMessageId": "server-input-\(suffix)",
                                   "messageId": "assistant-\(suffix)", "content": "Done"]),
            ("assistant.turn_end", ["turnId": "turn-\(suffix)"]),
            ("session.idle", [:]),
        ] {
            if scenario == "owner-idle-without-root" && type != "session.idle" { continue }
            if scenario == "owner-no-idle" && type == "session.idle" { continue }
            var payload = data
            if scenario == "owner-foreign-root" && type == "assistant.message" {
                payload["originatingMessageId"] = "someone-else"
            }
            if scenario == "owner-aborted" && type == "session.idle" { payload["aborted"] = true }
            if scenario == "owner-streaming" && type == "assistant.message" {
                try sendEvent(sessionID: sessionID, type: "assistant.message_start", data: ["messageId": "assistant-one"])
                try sendEvent(
                    sessionID: sessionID, type: "assistant.message_delta",
                    data: ["messageId": "assistant-one", "deltaContent": "Done"]
                )
                try sendEvent(
                    sessionID: sessionID, type: "assistant.reasoning_delta",
                    data: ["reasoningId": "reason-one", "deltaContent": "Thinking"]
                )
                try sendEvent(
                    sessionID: sessionID, type: "assistant.reasoning",
                    data: ["reasoningId": "reason-one", "content": "Thinking complete"]
                )
            }
            try sendEvent(
                sessionID: sessionID, type: type, data: payload,
                eventID: type == "assistant.turn_start" ? replayEventID : nil, metadataScenario: scenario
            )
        }
    }

    static func sendEvent(
        sessionID: String, type: String, data: [String: Any],
        eventID: String? = nil, metadataScenario: String? = nil
    ) throws {
        var event: [String: Any] = [
            "id": eventID ?? UUID().uuidString, "timestamp": "2026-10-19T13:00:00.000Z",
            "parentId": NSNull(), "type": type, "data": data,
        ]
        if [
            "session.idle", "assistant.idle", "assistant.intent", "assistant.message_start",
            "assistant.message_delta", "assistant.reasoning_delta", "tool.execution_progress",
        ].contains(type) { event["ephemeral"] = true }
        if type == "assistant.turn_start" {
            switch metadataScenario {
            case "owner-root-missing-timestamp": event.removeValue(forKey: "timestamp")
            case "owner-root-wrong-parent": event["parentId"] = "foreign"
            case "owner-root-v5-id": event["id"] = "11111111-1111-5111-8111-111111111111"
            default: break
            }
        }
        if type == "session.idle" {
            if metadataScenario == "owner-root-numeric-ephemeral" { event["ephemeral"] = 1 }
            if metadataScenario == "owner-root-missing-ephemeral" { event.removeValue(forKey: "ephemeral") }
        }
        try send([
            "jsonrpc": "2.0", "method": "session.event",
            "params": ["sessionId": sessionID, "event": event],
        ])
    }

    static func sendConfiguration(_ scenario: String, sessionID: String, firstID: String? = nil) throws {
        var events: [(String, [String: Any])] = [
            ("session.tools_updated", ["model": "controlled-model"]),
            ("session.skills_loaded", ["skills": []]),
            ("session.custom_agents_updated", ["agents": [], "errors": [], "warnings": []]),
            ("session.mcp_servers_loaded", ["servers": []]),
            ("session.extensions_loaded", ["extensions": []]),
        ]
        if scenario == "configuration-before-start" {
            events = Array(events.prefix(1))
        } else if scenario == "configuration-limit" || scenario == "configuration-overflow" {
            events = Array(repeating: events[0], count: scenario == "configuration-limit" ? 63 : 64)
        }
        for (index, entry) in events.enumerated() {
            let (kind, original) = entry
            var data = original
            if scenario == "configuration-nonempty-model" && kind == "session.tools_updated" { data["model"] = "" }
            if scenario == "configuration-nonempty-extra" && index == 0 { data["unexpected"] = [] as [String] }
            for (suffix, key) in [
                ("skills", "skills"), ("agents", "agents"), ("errors", "errors"), ("warnings", "warnings"),
                ("mcp", "servers"), ("extensions", "extensions"),
            ] where scenario == "configuration-nonempty-\(suffix)" && data[key] != nil {
                data[key] = ["unexpected"]
            }
            if scenario == "configuration-foreign-parent" && index == 0 { data["parentToolCallId"] = "child-call" }
            var event: [String: Any] = [
                "id": index == 0 ? firstID ?? UUID().uuidString : UUID().uuidString,
                "type": kind, "data": data, "ephemeral": true,
                "parentId": NSNull(), "timestamp": "2026-10-19T13:00:00.000Z",
            ]
            if index == 0 {
                switch scenario {
                case "configuration-malformed-id": event["id"] = ""
                case "configuration-malformed-uuid-version": event["id"] = "11111111-1111-5111-8111-111111111111"
                case "configuration-malformed-timestamp": event["timestamp"] = "not-a-timestamp"
                case "configuration-malformed-parent": event["parentId"] = 1
                case "configuration-malformed-ephemeral": event["ephemeral"] = 1
                case "configuration-foreign-agent": event["agentId"] = "child"
                default: break
                }
            }
            let notification: [String: Any] = [
                "jsonrpc": "2.0", "method": "session.event",
                "params": ["sessionId": sessionID, "event": event],
            ]
            try send(notification)
            if scenario == "configuration-duplicate" && index == 0 { try send(notification) }
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
