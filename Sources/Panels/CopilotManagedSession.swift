import CmuxControlSocket
import CoreFoundation
import Foundation

/// Private owner-input transport and work evidence. Automatic input is not exposed.
@MainActor
final class CopilotManagedSession {
    enum Phase: String {
        case idle, connecting, creating, configuring, awaitingReadback, configurationObserved, held
        case sending, awaitingRoot, inspectingWork, workObserved
        case executingCallback, respondingCallback
    }

    let sessionID = UUID().uuidString.lowercased()
    private(set) var phase: Phase = .idle
    private(set) var holdReason: String?
    private(set) var bufferedEvents: [Data] = []
    private(set) var diagnostics = Data()
    private(set) var closeFailures: [String] = []
    var failureSink: ((String) -> Void)?

    var hasCompleteWorkEvidence: Bool {
        phase == .workObserved && lifetime.transportIsLive(launchID: lifetime.launchID)
            && turnLedger?.hasCompleteWorkEvidence == true && (codingAuthority?.outstandingWorkCount ?? 0) == 0
            && commandAuthorityIsLive
    }
    var inputState: ShepherdManagedSessionState? { turnLedger?.state }

    func submitOwnerInput(_ inputID: UUID, prompt: String, launchID: UUID) -> Bool {
        guard launchID == lifetime.launchID,
              phase == .configurationObserved || phase == .workObserved,
              pending.isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard lifetime.transportIsLive(launchID: launchID), let identity = lifetime.identity,
              let turnLedger, turnLedger.state.identity == identity, commandAuthorityIsLive else {
            hold("transportUnavailable")
            return false
        }
        guard turnLedger.beginInput(inputID, origin: .owner) else {
            hold("inputLedgerConflict")
            return false
        }
        phase = .sending
        request(.send(inputID), params: [
            "sessionId": sessionID, "prompt": prompt, "source": "user",
            "agentMode": "interactive", "mode": "enqueue",
        ])
        return phase != .held
    }

    private enum Method {
        case connect, create, options
        case readback(CopilotManagedConfiguration.Readback)
        case send(UUID)
        case work(CopilotManagedTurnLedger.WorkReadback, UUID)
        case callback(String)

        var ownsConfigurationMutation: Bool {
            switch self {
            case .create, .options, .readback(.initializeTools): true
            default: false
            }
        }

        var requiresCommandAuthority: Bool {
            switch self {
            case .send, .work, .callback: true
            default: false
            }
        }

        var name: String {
            switch self {
            case .connect: "connect"
            case .create: "session.create"
            case .options: "session.options.update"
            case .readback(let readback): readback.method
            case .send: "session.send"
            case .callback: "session.tools.handlePendingToolCall"
            case .work(let readback, _):
                switch readback {
                case .refresh: "session.tasks.refresh"
                case .tasks: "session.tasks.list"
                case .schedules: "session.schedule.list"
                case .pendingTools: "session.tools.listPendingRequests"
                }
            }
        }
    }

    private struct Pending {
        let method: Method
        var admitted = false
        var response: [String: Any]?
    }

    private let lifetime: AgentSessionManagedSession
    private let writer: ShepherdManagedPipeWriter
    private let workingDirectory: String
    private var framer = ShepherdManagedRPCFramer()
    private var pending: [String: Pending] = [:]
    private var writeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var bufferedEventBytes = 0
    private var startupEventID: UUID?
    private var startupEventIDs: Set<UUID> = []
    private var verifiedReadbacks: Set<CopilotManagedConfiguration.Readback> = []
    private var turnLedger: CopilotManagedTurnLedger?
    private let codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority?
    private var commandTask: Task<Void, Never>?
    private var commandAuthorityIsLive: Bool {
        codingAuthority == nil || codingAuthority?.isLive(for: lifetime, workingDirectory: workingDirectory) == true
    }

    func waitForCommandSettlement() async { await commandTask?.value }

    init(
        lifetime: AgentSessionManagedSession, takingOwnershipOf input: FileHandle,
        workingDirectory: String,
        codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority? = nil
    ) throws {
        self.lifetime = lifetime
        self.writer = try ShepherdManagedPipeWriter(takingOwnershipOf: input)
        self.workingDirectory = workingDirectory
        self.codingAuthority = codingAuthority
        lifetime.outputSink = { [weak self] stream, bytes, launchID in
            self?.receive(stream: stream, bytes: bytes, launchID: launchID)
        }
        lifetime.heldSink = { [weak self] _, launchID in
            guard let self, launchID == self.lifetime.launchID else { return }
            self.hold("transportUnavailable")
        }
    }

    deinit {
        writeTask?.cancel()
        timeoutTask?.cancel()
        commandTask?.cancel()
    }

    func start(launchID: UUID) {
        guard launchID == lifetime.launchID, phase != .held else { return }
        guard phase == .idle else {
            hold("duplicateStart")
            return
        }
        guard lifetime.transportIsLive(launchID: launchID) else {
            hold("transportUnavailable")
            return
        }
        phase = .connecting
        request(.connect, params: ["supportedTaskKinds": ["agent", "client", "shell"]])
    }

    private func request(_ method: Method, params: [String: Any]) {
        guard phase != .held, pending.isEmpty else {
            hold("requestLedgerConflict")
            return
        }
        let id = UUID().uuidString.lowercased()
        let frame: Data
        do {
            frame = try ShepherdManagedRPCFramer.frame(JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": method.name, "params": params,
            ]))
        } catch {
            hold("requestEncodingFailed")
            return
        }
        // Register before scheduling the first byte; a peer can reply before write completion resumes.
        pending[id] = Pending(method: method)
        let launchID = lifetime.launchID
        writeTask = Task { [weak self] in
            guard let self, self.phase != .held else { return }
            let result = await self.writer.write(frame, deadline: .now.advanced(by: .seconds(2))) {
                self.phase != .held && self.lifetime.transportIsLive(launchID: launchID)
                    && (!method.requiresCommandAuthority || self.commandAuthorityIsLive)
            }
            guard self.phase != .held else { return }
            guard result == .complete(frame.count), self.pending[id] != nil else {
                self.hold("writeUnavailable")
                return
            }
            self.pending[id]?.admitted = true
            self.completeIfProven(id)
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { return }
            catch {
                self?.hold("responseTimerFailed")
                return
            }
            guard let self, self.pending[id] != nil else { return }
            self.hold("responseTimeout")
        }
    }

    private func receive(stream: String, bytes: Data, launchID: UUID) {
        guard launchID == lifetime.launchID, phase != .held else { return }
        guard lifetime.transportIsLive(launchID: launchID) else {
            hold("transportUnavailable")
            return
        }
        if stream == "stderr" {
            diagnostics.append(bytes.prefix(max(0, 8192 - diagnostics.count)))
            return
        }
        guard stream == "stdout" else {
            hold("unknownStream")
            return
        }
        do {
            for body in try framer.append(bytes) {
                guard phase != .held else { return }
                guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      envelope["jsonrpc"] as? String == "2.0" else {
                    hold("invalidEnvelope")
                    return
                }
                if envelope["method"] != nil {
                    receiveNotification(envelope, body: body)
                } else {
                    receiveResponse(envelope)
                }
            }
        } catch {
            hold("invalidEnvelope")
        }
    }

    private func receiveNotification(_ envelope: [String: Any], body: Data) {
        guard envelope["id"] == nil else {
            hold("unsupportedCallback")
            return
        }
        guard Set(envelope.keys) == ["jsonrpc", "method", "params"],
              envelope["method"] as? String == "session.event",
              let params = envelope["params"] as? [String: Any],
              let event = params["event"] as? [String: Any] else {
            hold("unsupportedNotification")
            return
        }
        guard params["sessionId"] as? String == sessionID else {
            hold("sessionMismatch")
            return
        }
        if event["type"] as? String != "session.start" {
            if let kind = event["type"] as? String, [
                "session.tools_updated", "session.skills_loaded", "session.custom_agents_updated",
                "session.mcp_servers_loaded", "session.extensions_loaded",
            ].contains(kind) {
                receiveConfigurationEvent(event, body: body, kind: kind)
                return
            }
            if let id = CopilotManagedEventMetadata.uuidV4(event["id"]), startupEventIDs.contains(id) {
                hold("replayedEvent")
                return
            }
            guard let turnLedger else {
                hold("unsupportedNotification")
                return
            }
            do {
                turnLedger.receive(try JSONSerialization.data(withJSONObject: event))
            } catch {
                hold("invalidEnvelope")
                return
            }
            if let reason = turnLedger.failureReason {
                hold(reason)
                return
            }
            if phase == .workObserved { phase = .awaitingRoot }
            dispatchCallbackIfReady()
            inspectWorkIfReady()
            return
        }
        guard phase == .creating || phase == .configuring || phase == .awaitingReadback
                || phase == .configurationObserved || startupEventID != nil else {
            hold("sessionMismatch")
            return
        }
        guard validateStartupEvent(event) else { return }
        guard startupEventID == nil else {
            hold("duplicateStartupEvent")
            return
        }
        guard let id = CopilotManagedEventMetadata.uuidV4(event["id"]) else {
            hold("invalidStartupEvent")
            return
        }
        guard bufferStartupEvent(id, body: body, duplicateReason: "duplicateStartupEvent") else { return }
        startupEventID = id
    }

    private func bufferStartupEvent(_ id: UUID, body: Data, duplicateReason: String) -> Bool {
        guard !startupEventIDs.contains(id) else {
            hold(duplicateReason)
            return false
        }
        guard bufferedEvents.count < 64, bufferedEventBytes + body.count <= 1_048_576 else {
            hold("eventBufferOverflow")
            return false
        }
        startupEventIDs.insert(id)
        bufferedEvents.append(body)
        bufferedEventBytes += body.count
        return true
    }

    private func receiveConfigurationEvent(_ event: [String: Any], body: Data, kind: String) {
        guard (phase == .creating || phase == .configuring || phase == .awaitingReadback),
              pending.values.contains(where: { $0.method.ownsConfigurationMutation }) else {
            hold("configurationChanged")
            return
        }
        guard event["agentId"] == nil,
              (event["data"] as? [String: Any])?["parentToolCallId"] == nil else {
            hold("foreignParticipant")
            return
        }
        guard Set(event.keys) == ["id", "type", "data", "parentId", "timestamp", "ephemeral"],
              let id = CopilotManagedEventMetadata.eventID(event), let data = event["data"] as? [String: Any] else {
            hold("invalidConfigurationEvent")
            return
        }
        let accepted: Bool
        switch kind {
        case "session.tools_updated":
            accepted = Set(data.keys) == ["model"]
                && (data["model"] as? String).map(ShepherdManagedSessionIdentity.validIdentifier) == true
        case "session.skills_loaded":
            accepted = CopilotManagedConfiguration.acceptsEmptyInventories(data, keys: ["skills"])
        case "session.custom_agents_updated":
            accepted = CopilotManagedConfiguration.acceptsEmptyInventories(data, keys: ["agents", "errors", "warnings"])
        case "session.mcp_servers_loaded":
            accepted = CopilotManagedConfiguration.Readback.mcp.accepts(data)
        case "session.extensions_loaded":
            accepted = CopilotManagedConfiguration.Readback.extensions.accepts(data)
        default:
            accepted = false
        }
        guard accepted else {
            hold("configurationMismatch")
            return
        }
        _ = bufferStartupEvent(id, body: body, duplicateReason: "replayedConfigurationEvent")
    }

    private func validateStartupEvent(_ event: [String: Any]) -> Bool {
        guard CopilotManagedEventMetadata.eventID(event) != nil,
              event["parentId"] is NSNull,
              let data = event["data"] as? [String: Any],
              data["copilotVersion"] as? String == "1.0.98",
              let producer = data["producer"] as? String, !producer.isEmpty,
              let started = data["startTime"] as? String, CopilotManagedEventMetadata.isTimestamp(started),
              let version = data["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue.isFinite, version.doubleValue > 0,
              version.doubleValue.rounded() == version.doubleValue else {
            hold("invalidStartupEvent")
            return false
        }
        for field in ["alreadyInUse", "remoteSteerable"] {
            if let value = data[field] {
                guard let boolean = value as? NSNumber,
                      CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                    hold("invalidStartupEvent")
                    return false
                }
                if boolean.boolValue {
                    hold("foreignParticipant")
                    return false
                }
            }
        }
        guard data["sessionId"] as? String == sessionID,
              data["detachedFromSpawningParentSessionId"] == nil, event["agentId"] == nil else {
            hold("foreignParticipant")
            return false
        }
        return true
    }

    private func receiveResponse(_ envelope: [String: Any]) {
        guard let id = envelope["id"] as? String,
              Set(envelope.keys).isSubset(of: ["jsonrpc", "id", "result", "error"]),
              (envelope["result"] != nil) != (envelope["error"] != nil) else {
            hold("invalidEnvelope")
            return
        }
        guard var registered = pending[id], registered.response == nil else {
            hold("unregisteredResponse")
            return
        }
        guard envelope["error"] == nil else {
            hold("rpcError")
            return
        }
        guard let result = envelope["result"] as? [String: Any] else {
            hold("invalidEnvelope")
            return
        }
        registered.response = result
        pending[id] = registered
        completeIfProven(id)
    }

    private func completeIfProven(_ id: String) {
        guard let registered = pending[id], registered.admitted,
              let response = registered.response else { return }
        guard lifetime.transportIsLive(launchID: lifetime.launchID) else {
            hold("transportUnavailable")
            return
        }
        guard !registered.method.requiresCommandAuthority || commandAuthorityIsLive else {
            hold("commandAuthorityUnavailable")
            return
        }
        pending.removeValue(forKey: id)
        timeoutTask?.cancel()
        switch registered.method {
        case .connect:
            guard CopilotManagedEventMetadata.boolean(response["ok"]) == true,
                  response["protocolVersion"] as? Int == 3,
                  response["version"] as? String == "1.0.98" else {
                hold("incompatiblePeer")
                return
            }
            phase = .creating
            request(.create, params: CopilotManagedConfiguration.createParameters(
                sessionID: sessionID, workingDirectory: workingDirectory, nativeForegroundTool: codingAuthority != nil
            ))
        case .create:
            guard response["sessionId"] as? String == sessionID else {
                hold("sessionMismatch")
                return
            }
            guard lifetime.acceptProviderHandshake(sessionID: sessionID, launchID: lifetime.launchID) else {
                hold("transportUnavailable")
                return
            }
            phase = .configuring
            request(.options, params: CopilotManagedConfiguration.optionParameters(
                sessionID: sessionID, nativeForegroundTool: codingAuthority != nil
            ))
        case .options:
            guard CopilotManagedEventMetadata.boolean(response["success"]) == true,
                  response["pluginHookCount"] as? Int == 0 else {
                hold("configurationRefused")
                return
            }
            guard startupEventID != nil else {
                hold("startupEventUnavailable")
                return
            }
            phase = .awaitingReadback
            requestReadback(.initializeTools)
        case .readback(let readback):
            guard phase == .awaitingReadback, readback.accepts(response, nativeForegroundTool: codingAuthority != nil),
                  verifiedReadbacks.insert(readback).inserted else {
                hold("configurationMismatch")
                return
            }
            let steps = CopilotManagedConfiguration.Readback.allCases
            if let next = steps.first(where: { !verifiedReadbacks.contains($0) }) {
                requestReadback(next)
            } else {
                guard let identity = lifetime.identity else {
                    hold("transportUnavailable")
                    return
                }
                guard codingAuthority == nil
                        || codingAuthority?.isLive(for: lifetime, workingDirectory: workingDirectory) == true else {
                    hold("commandAuthorityUnavailable")
                    return
                }
                turnLedger = CopilotManagedTurnLedger(
                    identity: identity, allowsForegroundCommands: codingAuthority != nil, workingDirectory: workingDirectory
                )
                phase = .configurationObserved
            }
        case .send(let inputID):
            guard phase == .sending, Set(response.keys) == ["messageId"],
                  let messageID = response["messageId"] as? String,
                  ShepherdManagedSessionIdentity.validIdentifier(messageID) else {
                hold("invalidSendAcknowledgement")
                return
            }
            guard let turnLedger, turnLedger.acknowledgeInput(inputID, providerInputID: messageID) else {
                hold(turnLedger?.failureReason ?? "inputLedgerConflict")
                return
            }
            phase = .awaitingRoot
            dispatchCallbackIfReady()
            inspectWorkIfReady()
        case .callback(let callID):
            guard phase == .respondingCallback, Set(response.keys) == ["success"],
                  CopilotManagedEventMetadata.boolean(response["success"]) == true,
                  codingAuthority?.isLive(for: lifetime, workingDirectory: workingDirectory) == true,
                  codingAuthority?.outstandingWorkCount == 0,
                  turnLedger?.acknowledgeCallback(callID) == true else {
                hold("invalidCallbackAcknowledgement")
                return
            }
            phase = .awaitingRoot
            dispatchCallbackIfReady()
            inspectWorkIfReady()
        case .work(let readback, let token):
            guard phase == .inspectingWork, let turnLedger,
                  turnLedger.acceptWorkReadback(readback, token: token, result: response) else {
                hold(turnLedger?.failureReason ?? "workReadbackMismatch")
                return
            }
            let steps = CopilotManagedTurnLedger.WorkReadback.allCases
            guard let index = steps.firstIndex(of: readback) else {
                hold("workReadbackMismatch")
                return
            }
            if index + 1 < steps.count {
                request(.work(steps[index + 1], token), params: ["sessionId": sessionID])
            } else {
                guard turnLedger.hasCompleteWorkEvidence else {
                    hold("workReadbackMismatch")
                    return
                }
                phase = .workObserved
            }
        }
    }

    private func inspectWorkIfReady() {
        guard phase == .awaitingRoot, pending.isEmpty,
              let token = turnLedger?.beginWorkReadback() else { return }
        phase = .inspectingWork
        request(.work(.refresh, token), params: ["sessionId": sessionID])
    }

    private func dispatchCallbackIfReady() {
        guard phase == .awaitingRoot, pending.isEmpty, commandTask == nil,
              let callback = turnLedger?.nextCallback else { return }
        guard let codingAuthority,
              codingAuthority.isLive(for: lifetime, workingDirectory: workingDirectory),
              let requestID = callback.requestID, turnLedger?.dispatchCallback(callback.callID) == true else {
            hold("commandAuthorityUnavailable")
            return
        }
        phase = .executingCallback
        let operationID = UUID()
        commandTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await codingAuthority.execute(callback.command, operationID: operationID)
            self.commandTask = nil
            guard self.phase != .held else { return }
            guard codingAuthority.isLive(for: self.lifetime, workingDirectory: self.workingDirectory) else {
                self.hold("commandAuthorityUnavailable")
                return
            }
            switch outcome {
            case .held(let reason):
                self.hold("commandHeld:\(reason.rawValue)")
            case .completed(let completion):
                guard self.turnLedger?.registerCallbackResponse(callback.callID) == true else {
                    self.hold("callbackMismatch")
                    return
                }
                let limit = 16 * 1024
                let report: [String: Any] = [
                    "status": completion.status,
                    "stdout": String(decoding: completion.stdout.prefix(limit), as: UTF8.self),
                    "stderr": String(decoding: completion.stderr.prefix(limit), as: UTF8.self),
                    "stdoutBytes": completion.stdout.count, "stderrBytes": completion.stderr.count,
                    "stdoutTruncated": completion.stdout.count > limit, "stderrTruncated": completion.stderr.count > limit,
                    "decoding": "utf8-replacement",
                ]
                do {
                    let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                    let text = String(decoding: encoded, as: UTF8.self)
                    self.phase = .respondingCallback
                    self.request(.callback(callback.callID), params: [
                        "sessionId": self.sessionID, "requestId": requestID,
                        "result": ["textResultForLlm": text, "resultType": completion.status == 0 ? "success" : "failure"],
                    ])
                } catch {
                    self.hold("callbackResultEncodingFailed")
                }
            }
        }
    }

    private func requestReadback(_ readback: CopilotManagedConfiguration.Readback) {
        var params: [String: Any] = ["sessionId": sessionID]
        if readback == .agents { params["includeBuiltInAgents"] = true }
        request(.readback(readback), params: params)
    }

    private func hold(_ reason: String) {
        guard phase != .held else { return }
        phase = .held
        holdReason = reason
        pending.removeAll()
        writeTask?.cancel()
        timeoutTask?.cancel()
        commandTask?.cancel()
        codingAuthority?.revoke()
        do { try writer.close() } catch { closeFailures.append("stdin: \(error)") }
        do { try lifetime.abandon() } catch { closeFailures.append("output: \(error)") }
        failureSink?(reason)
    }
}
