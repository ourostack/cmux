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
            let deadline = ContinuousClock.now.advanced(by: .seconds(scenario == "timeout" ? 7 : 2))
            while adapter.phase != .held && adapter.phase.rawValue != "configurationObserved"
                    && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            // A duplicate response must still invalidate a completed startup.
            try await Task.sleep(for: .milliseconds(80))
        }
        if scenario.hasPrefix("owner-") && scenario != "owner-before-start" {
            inputAccepted = adapter.submitOwnerInput(
                hostInputID, prompt: scenario == "owner-whitespace" ? " \n\t" : "Owner input: 雪 🐈",
                launchID: scenario == "owner-stale-launch" ? UUID() : lifetime.launchID
            )
            if scenario != "owner-stale-launch" && scenario != "owner-whitespace" {
                secondAccepted = adapter.submitOwnerInput(UUID(), prompt: "must not queue", launchID: lifetime.launchID)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while adapter.phase != .held && !adapter.hasCompleteWorkEvidence && ContinuousClock.now < deadline {
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
        return [
            "phase": adapter.phase.rawValue, "reason": adapter.holdReason ?? "",
            "nativePhase": ManagedSessionLifetimeFixture.phase(lifetime),
            "sessionID": adapter.sessionID,
            "boundSessionID": lifetime.identity?.providerSessionID ?? "",
            "bufferedEvents": adapter.bufferedEvents.count,
            "nativeBeforeStart": beforeStart,
            "inputAccepted": inputAccepted, "secondAccepted": secondAccepted,
            "workEvidence": adapter.hasCompleteWorkEvidence,
            "ackMatchesHost": adapter.inputState?.inputID(matchingProviderInputID: "server-input-one") == hostInputID,
            "nextAccepted": nextAccepted,
            "nextAckMatchesHost": adapter.inputState?.inputID(matchingProviderInputID: "server-input-two") == nextHostInputID,
        ]
    }

    static func peer(_ scenario: String) throws {
        var framer = ShepherdManagedRPCFramer()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var plannedID: String?
        var requestedNoBuiltinAgents = false
        var sentInputs = 0
        var workStep = 0
        var initializedTools = false
        var readbackStep = 0
        var configurationEventID: String?
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
                    if scenario == "strict-profile" {
                        guard params["includedBuiltinAgents"] as? [String] == [],
                              params["sessionCapabilities"] as? [String] == [],
                              params["continueOnAutoMode"] as? Bool == false else {
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
                    result = ["tools": scenario == "null-tools" ? NSNull()
                              : scenario == "unaccounted-tool" ? [["name": "unexpected"]] : []]
                case "session.send":
                    guard scenario.hasPrefix("owner-"), sentInputs == 0 || (
                            sentInputs == 1 && ["owner-next-input", "owner-reused-provider", "owner-late-prior-root"]
                                .contains(scenario)
                          ),
                          Set(params.keys) == ["sessionId", "prompt", "source", "agentMode", "mode"],
                          params["sessionId"] as? String == plannedID,
                          params["prompt"] as? String == "Owner input: 雪 🐈",
                          params["source"] as? String == "user",
                          params["agentMode"] as? String == "interactive",
                          params["mode"] as? String == "enqueue",
                          let plannedID else { throw POSIXError(.EPROTO) }
                    sentInputs += 1
                    workStep = 0
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
                    if scenario == "owner-duplicate-ack" { try send(response) }
                    if scenario == "owner-configuration-changed" {
                        try sendConfiguration("configuration-before-start", sessionID: plannedID)
                    }
                    if scenario != "owner-early-root" && scenario != "owner-ack-only" {
                        try sendRoot(
                            sessionID: plannedID, scenario: scenario,
                            input: scenario == "owner-late-prior-root" ? 1 : sentInputs,
                            replayEventID: scenario == "owner-configuration-replay" ? configurationEventID : nil
                        )
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
                if scenario == "duplicate" { try send(response) }
                if scenario == "configuration-late" && method == "session.tools.getCurrentMetadata" {
                    try sendConfiguration("configuration-before-start", sessionID: plannedID!)
                }
            }
        }
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
            "assistant.message_delta", "assistant.reasoning_delta",
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
