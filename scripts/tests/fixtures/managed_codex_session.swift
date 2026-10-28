import CmuxControlSocket
import CmuxFoundation
import CryptoKit
import Darwin
import Foundation

#if !SHEPHERD_STORE_SOURCE_TEST
@main
#endif
struct ManagedCodexSessionFixture {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.count == 2, args[0] == "--fixture-codex-session" {
                let bytes = FileHandle.standardInput.readDataToEndOfFile()
                guard let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw POSIXError(.EPROTO)
                }
                let result = try await run(args[1], request: request)
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                return
            }
            if args.count == 5, args[0] == "--private-stdio", args[1] == "--boot-nonce", args[3] == "--cwd" {
                try peer(nonce: args[2], directory: args[4])
                return
            }
            guard let command = args.first,
                  let supervisor = try OwnedProcessSupervisor(command: command, arguments: Array(args.dropFirst())) else {
                throw POSIXError(.EINVAL)
            }
            exit(try supervisor.run())
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run(_ scenario: String, request: [String: Any]) async throws -> [String: Any] {
        final class Store {}
        let store = Store()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-codex-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: request)
            .write(to: directory.appendingPathComponent(".controlled-codex-config"))
        let provider: ShepherdManagedProvider = scenario == "wrong-provider" ? .copilot : .codex
        let owner: AgentSessionManagedNativeOwner?
        if scenario == "production-unqualified" {
            owner = .issueForFreshNativePanel(
                newPanelID: UUID(), workspaceID: UUID(), rendererID: "react", workingDirectory: directory.path,
                owningStore: store, isCurrentOwner: { true }, provider: provider)
        } else {
            owner = .init(
                newPanelID: UUID(), workspaceID: UUID(), rendererID: "react", workingDirectory: directory.path,
                owningStore: store, isCurrentOwner: { true }, provider: provider)
        }
        guard let owner else { throw POSIXError(.EPERM) }
        if scenario != "unconsumed-owner" {
            guard owner.consume(
                for: store, scope: owner.scope, workingDirectory: directory.path, projectMandate: owner.projectMandate
            ) else { throw POSIXError(.EPERM) }
        }
        if scenario == "revoked-owner" { owner.revoke() }
        let scope = scenario == "wrong-scope" ? AgentSessionManagedNativeOwner.Scope(
            hostInstance: owner.scope.hostInstance, workspaceID: owner.scope.workspaceID,
            surfaceID: UUID(), generation: 1) : owner.scope
        var launch: AgentSessionManagedCodexLaunch?
        do {
            launch = try await .prepare(
                scope: scope, executableURL: executable, workingDirectory: directory.path, nativeOwner: owner,
                launcher: AgentSessionOwnedProcessLauncher(supervisorExecutableURL: executable))
            try launch?.launchBackend()
        } catch {
            if let launch { try await launch.close() }
            return ["rejected": true, "error": String(describing: error),
                    "peerStarted": FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(".controlled-codex-started").path)]
        }
        guard let launch else { throw POSIXError(.EPROTO) }
        let adapter = launch.adapter
        var projections: [[String: Any]] = []
        adapter.projectionSink = { projection in
            switch projection {
            case .assistant(let text): projections.append(["kind": "assistant", "text": text])
            case .commandStarted(let id, _): projections.append(["kind": "commandStarted", "id": id])
            case .commandCompleted(let id, _, let status, let text):
                if scenario.hasPrefix("command-output-") {
                    projections.append([
                        "kind": "commandCompleted", "id": id, "status": status,
                        "text": String(text.prefix(128)), "textUTF8Bytes": text.utf8.count,
                    ])
                } else {
                    projections.append(["kind": "commandCompleted", "id": id, "status": status, "text": text])
                }
            case .turnComplete: projections.append(["kind": "turnComplete"])
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !adapter.configurationObserved && adapter.holdReason == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let configured = adapter.configurationObserved
        let boundThread = launch.lifetime.identity?.providerSessionID ?? ""
        let backendPID = launch.lifetime.backendIdentity?.pid ?? 0
        let inputID = UUID()
        var accepted = false, secondAccepted = false
        var supervisorResult: [String: Any] = [:]
        if scenario != "startup" && scenario != "wrong-descriptor", configured {
            accepted = adapter.submitOwnerInput(
                inputID, prompt: "controlled owner: 雪", launchID: launch.lifetime.launchID)
            secondAccepted = adapter.submitOwnerInput(
                UUID(), prompt: "must not queue", launchID: launch.lifetime.launchID)
            while !adapter.hasCompleteWorkEvidence && adapter.holdReason == nil && ContinuousClock.now < deadline {
                if scenario == "command-revoked", launch.codingAuthority.outstandingWorkCount == 1 {
                    owner.revoke()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            if scenario == "late-ack" { try await Task.sleep(for: .milliseconds(100)) }
        }
        if scenario.hasPrefix("supervisor") {
            supervisorResult = try await runSupervisor(
                scenario, adapter: adapter, launch: launch, owner: owner, store: store)
        }
        if adapter.holdReason != nil { await adapter.waitForCommandSettlement() }
        let trace = try readJSON(directory.appendingPathComponent(".controlled-codex-results"), fallback: [])
        let traceMethods = try readJSON(directory.appendingPathComponent(".controlled-codex-methods"), fallback: [])
        let executions = directory.appendingPathComponent("executions")
        var result: [String: Any] = [
            "configured": configured, "boundThread": boundThread,
            "profileMatches": SHA256.hash(data: launch.profileManifest).map { String(format: "%02x", $0) }.joined()
                == CodexManagedStartup.profileSHA256,
            "reactQualified": AgentSessionManagedNativeOwner.hasQualifiedNativeProfile(rendererID: "react", provider: .codex),
            "solidQualified": AgentSessionManagedNativeOwner.hasQualifiedNativeProfile(rendererID: "solid", provider: .codex),
            "backendPID": backendPID, "supervisorPID": launch.processIdentifier,
            "inputAccepted": accepted, "secondAccepted": secondAccepted,
            "complete": adapter.hasCompleteWorkEvidence, "reason": adapter.holdReason ?? "",
            "ackMatchesHost": adapter.inputState?.inputID(matchingProviderInputID: "controlled-turn-A") == inputID,
            "outstanding": adapter.inputState?.outstandingActivityCount ?? 0,
            "nativeOutstanding": launch.codingAuthority.outstandingWorkCount,
            "peerResults": trace, "peerMethods": traceMethods, "projections": projections,
            "peerInputs": try readJSON(directory.appendingPathComponent(".controlled-codex-inputs"), fallback: []),
            "partialBytes": try readJSON(directory.appendingPathComponent(".controlled-codex-partial"), fallback: 0),
            "executions": FileManager.default.fileExists(atPath: executions.path)
                ? try String(contentsOf: executions, encoding: .utf8) : "",
        ]
        result.merge(supervisorResult) { _, value in value }
        do {
            try await launch.close()
            result["cleanupError"] = ""
        } catch { result["cleanupError"] = String(describing: error) }
        return result
    }

    @MainActor private static func runSupervisor(
        _ scenario: String, adapter: CodexManagedSession, launch: AgentSessionManagedCodexLaunch,
        owner: AgentSessionManagedNativeOwner, store: AnyObject
    ) async throws -> [String: Any] {
        let ownerComplete = adapter.hasCompleteWorkEvidence
        let identity = launch.lifetime.identity
        let host = NSObject()
        let controller = AgentSessionManagedRendererController(
            context: {
                .init(
                    owner: ObjectIdentifier(owner), store: ObjectIdentifier(store),
                    coordinator: ObjectIdentifier(host), host: ObjectIdentifier(host),
                    webView: ObjectIdentifier(host), window: ObjectIdentifier(host), responder: ObjectIdentifier(host),
                    workspaceID: owner.scope.workspaceID, panelID: owner.scope.surfaceID,
                    renderer: "react", document: "file:///controlled/codex-managed.html",
                    paintGeneration: 1, geometry: [0, 0, 800, 600])
            },
            operation: { operation in
                switch operation {
                case .capture: return ["editorText": "", "editVersion": "edit-1",
                                       "render": "paint-1", "screen": "Visible output"]
                case .reserve: return ["leaseId": "lease-1", "render": "paint-2"]
                case .validate, .consume: return true
                case .release: return nil
                }
            },
            onReleaseError: { error in fatalError("unexpected controlled release failure: \(error)") })
        let inputID = UUID()
        let cancellation = AgentSessionManagedInputCancellation()
        let prompt = scenario == "supervisor-partial"
            ? String(repeating: "x", count: 65536) : "Continue authorized coding: 雪"
        guard let snapshot = try await controller.capture(),
              let insertion = try await controller.insert(snapshot, text: prompt),
              let submission = try await controller.prepareSubmission(
                insertion, inputID: inputID, cancellation: cancellation) else { throw POSIXError(.EPROTO) }
        let foreignStore = NSObject()
        let candidate: AgentSessionManagedNativeOwner
        if scenario == "supervisor-foreign-owner" {
            guard let foreign = AgentSessionManagedNativeOwner(
                newPanelID: UUID(), workspaceID: owner.scope.workspaceID, rendererID: "react",
                workingDirectory: owner.workingDirectory, owningStore: store,
                isCurrentOwner: { true }, provider: .codex) else { throw POSIXError(.EPERM) }
            candidate = foreign
        } else { candidate = owner }
        if scenario == "supervisor-cancelled" { cancellation.cancel() }
        var progress: [[String: Any]] = []
        var scopeMatches = true
        let accepted = adapter.beginSupervisorInput(
            submission, nativeOwner: candidate,
            owningStore: scenario == "supervisor-foreign-store" ? foreignStore : store,
            progress: { value in
                scopeMatches = scopeMatches && value.inputID == inputID && value.identity == identity
                progress.append([
                    "inserted": value.editorInserted, "written": value.backendWriteAdmitted,
                    "provider": value.providerInputID ?? "", "failure": value.failureReason ?? "",
                ])
            })
        let repeated = accepted && adapter.beginSupervisorInput(
            submission, nativeOwner: owner, owningStore: store, progress: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while accepted && !adapter.hasCompleteWorkEvidence && adapter.holdReason == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Let the controlled peer drain already-written bytes after its invalidating event.
        if scenario == "supervisor-partial" { try await Task.sleep(for: .milliseconds(150)) }
        return [
            "ownerComplete": ownerComplete, "supervisorAccepted": accepted,
            "repeatedSupervisorAccepted": repeated, "progressScopeMatches": scopeMatches, "progress": progress,
        ]
    }

    private static func readJSON(_ path: URL, fallback: Any) throws -> Any {
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: path), options: .fragmentsAllowed)
    }

    static func peer(nonce: String, directory: String) throws {
        let root = URL(fileURLWithPath: directory)
        guard let config = try readJSON(root.appendingPathComponent(".controlled-codex-config"), fallback: [:])
                as? [String: Any],
              let scenario = config["scenario"] as? String,
              var descriptor = config["descriptor"] as? [String: Any],
              var params = descriptor["params"] as? [String: Any],
              var effective = params["effective"] as? [String: Any],
              var ready = config["ready"] as? [String: Any],
              var thread = ready["thread"] as? [String: Any] else { throw POSIXError(.EPROTO) }
        try Data("started".utf8).write(to: root.appendingPathComponent(".controlled-codex-started"))
        let storeID = "cmux-" + nonce
        params["bootNonce"] = nonce
        params["cwd"] = directory
        params["storeId"] = storeID
        effective["threadStore"] = ["type": "inMemory", "id": storeID]
        params["effective"] = effective
        if scenario == "wrong-descriptor" { params["profileDigest"] = String(repeating: "0", count: 64) }
        descriptor["params"] = params
        ready["cwd"] = directory
        thread["cwd"] = directory
        ready["thread"] = thread
        try send(descriptor)
        var decoder = CodexManagedStreamDecoder()
        var methods: [String] = []
        var results: [[String: Any]] = []
        var commands = 0
        var completedCommands = 0
        var inputs: [String] = []
        var currentTurn = "controlled-turn-A"
        var awaitingPartial = false
        var partialInvalidated = false
        var partialBytes = 0
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, awaitingPartial && !partialInvalidated ? 1 : bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            let messages = try decoder.append(Data(bytes.prefix(count)))
            if awaitingPartial {
                partialBytes += count
                try JSONSerialization.data(withJSONObject: partialBytes, options: .fragmentsAllowed)
                    .write(to: root.appendingPathComponent(".controlled-codex-partial"))
                if !partialInvalidated {
                    partialInvalidated = true
                    try sendLifecycle("turn/started", status: "inProgress", turnID: "foreign-early-turn")
                    usleep(100_000)
                }
            }
            for message in messages {
                if let method = message.object["method"] as? String {
                    methods.append(method)
                    try JSONSerialization.data(withJSONObject: methods)
                        .write(to: root.appendingPathComponent(".controlled-codex-methods"))
                    guard let id = message.object["id"], let request = message.object["params"] as? [String: Any] else {
                        throw POSIXError(.EPROTO)
                    }
                    switch method {
                    case "cmux/initialize":
                        guard Set(request.keys) == ["bootNonce", "profileDigest"],
                              request["bootNonce"] as? String == nonce,
                              request["profileDigest"] as? String == CodexManagedStartup.profileSHA256 else {
                            throw POSIXError(.EPROTO)
                        }
                        try send(["id": id, "result": ready])
                    case "turn/start":
                        guard Set(request.keys) == ["threadId", "input"],
                              request["threadId"] as? String == "actual-controlled-sdk-thread",
                              let input = request["input"] as? [[String: Any]], input.count == 1,
                              let text = input[0]["text"] as? String,
                              text == (inputs.isEmpty ? "controlled owner: 雪"
                                : scenario == "supervisor-partial" ? String(repeating: "x", count: 65536)
                                : "Continue authorized coding: 雪") else {
                            throw POSIXError(.EPROTO)
                        }
                        inputs.append(text)
                        try JSONSerialization.data(withJSONObject: inputs)
                            .write(to: root.appendingPathComponent(".controlled-codex-inputs"))
                        currentTurn = inputs.count == 1 ? "controlled-turn-A" : "controlled-turn-B"
                        try send(["id": id, "result": ["turn": turn("inProgress", turnID: currentTurn)]])
                        try sendLifecycle("turn/started", status: "inProgress", turnID: currentTurn)
                        if scenario.hasPrefix("command") {
                            commands = scenario == "command-overlap" ? 2 : 1
                            for index in 0..<commands {
                                let call = index == 0 ? "A" : "B"
                                let command = command(call, scenario: scenario)
                                try sendItem("item/started", item: tool(call, command: command))
                                try send(["id": "callback-" + call, "method": "item/tool/call", "params": [
                                    "threadId": "actual-controlled-sdk-thread", "turnId": "controlled-turn-A",
                                    "callId": call, "namespace": NSNull(), "tool": "cmux_run_foreground", "arguments": command,
                                ]])
                            }
                        } else { try finishTurn(turnID: currentTurn) }
                    case "thread/backgroundTerminals/list":
                        if scenario == "supervisor-partial", inputs.count == 1 { awaitingPartial = true }
                        try send(["id": id, "result": ["data": [], "nextCursor": NSNull()]])
                        if scenario == "late-ack" {
                            usleep(20_000)
                            try send(["id": "cmux-turn-foreign-old-root", "result": ["turn": turn("inProgress")]])
                        }
                    default: throw POSIXError(.EPROTO)
                    }
                } else {
                    guard let id = message.object["id"] as? String, id.hasPrefix("callback-"),
                          let result = message.object["result"] as? [String: Any],
                          let content = result["contentItems"] as? [[String: Any]], content.count == 1,
                          var text = content[0]["text"] as? String,
                          let success = result["success"] as? Bool,
                          let newline = text.firstIndex(of: "\n") else { throw POSIXError(.EPROTO) }
                    let prefix = String(text[..<newline])
                    let nonce = String(prefix.dropFirst("cmux-owned-result:".count))
                    let nonceValid = prefix.hasPrefix("cmux-owned-result:") && UUID(uuidString: nonce) != nil
                    let body = String(text[text.index(after: newline)...])
                    let report = try JSONSerialization.jsonObject(with: Data(body.utf8))
                    results.append([
                        "nonceValid": nonceValid, "nonce": nonce, "success": success,
                        "report": report, "reportUTF8Bytes": body.utf8.count,
                    ])
                    try JSONSerialization.data(withJSONObject: results)
                        .write(to: root.appendingPathComponent(".controlled-codex-results"))
                    if scenario == "command-fallback" { text = body }
                    if scenario == "command-wrong-echo" { text = "cmux-owned-result:\(UUID().uuidString.lowercased())\n" + body }
                    let call = String(id.dropFirst("callback-".count))
                    var item = tool(call, command: command(call, scenario: scenario))
                    item["status"] = success ? "completed" : "failed"
                    item["success"] = success
                    item["contentItems"] = [["type": "inputText", "text": text]]
                    try sendItem("item/completed", item: item)
                    completedCommands += 1
                    if completedCommands == commands { try finishTurn() }
                }
            }
        }
    }

    private static func command(_ call: String, scenario: String) -> [String: Any] {
        let output: String
        switch scenario {
        case "command-output-200k":
            output = "/usr/bin/head -c 204800 /dev/zero | LC_ALL=C /usr/bin/tr '\\000' A"
        case "command-output-both-limits":
            output = "/usr/bin/head -c 262144 /dev/zero | LC_ALL=C /usr/bin/tr '\\000' '\\377'; "
                + "/usr/bin/head -c 262144 /dev/zero | LC_ALL=C /usr/bin/tr '\\000' '\\376' >&2"
        case "command-output-overflow":
            output = "/usr/bin/head -c 262145 /dev/zero | LC_ALL=C /usr/bin/tr '\\000' A"
        default:
            output = "printf 'native output: 雪\\n'; printf 'native diagnostic\\n' >&2"
        }
        let sleep = scenario == "command-revoked" ? "sleep 1; " : ""
        let status = scenario == "command-failed" ? 7 : 0
        return ["program": "/bin/sh", "arguments": [
            "-c", "\(sleep)printf '\(call)\\n' >> executions; \(output); exit \(status)",
        ]]
    }

    private static func tool(_ call: String, command: [String: Any]) -> [String: Any] {
        ["type": "dynamicToolCall", "id": call, "namespace": NSNull(), "tool": "cmux_run_foreground",
         "arguments": command, "status": "inProgress", "contentItems": NSNull(),
         "success": NSNull(), "durationMs": NSNull()]
    }

    private static func turn(
        _ status: String, summary: [String: Any]? = nil, turnID: String = "controlled-turn-A"
    ) -> [String: Any] {
        ["id": turnID, "items": summary.map { [$0] } ?? [],
         "itemsView": summary == nil ? "notLoaded" : "summary", "status": status,
         "error": NSNull(), "startedAt": NSNull(), "completedAt": NSNull(), "durationMs": NSNull()]
    }

    private static func sendLifecycle(
        _ method: String, status: String, summary: [String: Any]? = nil, turnID: String = "controlled-turn-A"
    ) throws {
        try send(["method": method, "params": [
            "threadId": "actual-controlled-sdk-thread", "turn": turn(status, summary: summary, turnID: turnID),
        ]])
    }

    private static func sendItem(
        _ method: String, item: [String: Any], turnID: String = "controlled-turn-A"
    ) throws {
        try send(["method": method, "params": [
            "threadId": "actual-controlled-sdk-thread", "turnId": turnID, "item": item,
            method == "item/started" ? "startedAtMs" : "completedAtMs": 1,
        ]])
    }

    private static func finishTurn(turnID: String = "controlled-turn-A") throws {
        let item: [String: Any] = [
            "type": "agentMessage", "id": "assistant-" + turnID, "text": "controlled assistant: 雪",
            "phase": "final_answer", "memoryCitation": NSNull(), "delivery": NSNull(), "questions": NSNull(),
        ]
        try sendItem("item/started", item: item, turnID: turnID)
        try sendItem("item/completed", item: item, turnID: turnID)
        try sendLifecycle("turn/completed", status: "completed", summary: item, turnID: turnID)
    }

    private static func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

#if !SHEPHERD_STORE_SOURCE_TEST
struct AgentSessionLaunchPlan {
    let provider: AgentSessionProviderFixture
    let executableURL: URL
    let arguments: [String]
}
struct AgentSessionProviderFixture { let displayName: String }
enum AgentSessionBridgeError: Error { case providerNotReady(String) }
#endif
