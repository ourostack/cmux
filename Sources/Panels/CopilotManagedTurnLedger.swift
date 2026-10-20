import CmuxControlSocket
import Foundation

/// Provider event attribution and positive work evidence, never profile qualification or input admission.
@MainActor
final class CopilotManagedTurnLedger {
    enum Projection {
        case assistant(String)
        case commandStarted(String, AgentSessionManagedCommand)
        case commandCompleted(String, AgentSessionManagedCommand, Int32, String)
        case turnComplete
    }

    enum WorkReadback: String, CaseIterable {
        case refresh, tasks, schedules, pendingTools
    }

    private(set) var state: ShepherdManagedSessionState
    private(set) var failureReason: String?
    private var projections: [Projection] = []

    func takeProjections() -> [Projection] {
        defer { projections.removeAll() }
        return failureReason == nil ? projections : []
    }

    private struct Root {
        let input: UUID
        let providerInputID: String
        let turnID: String
        var ended = false
    }

    private struct Inspection {
        let token: UUID
        let root: Root
        let eventRevision: UUID
        let activityRevision: UUID
        var acceptedSteps = 0
    }

    private var inputID: UUID?
    private var providerInputID: String?
    private var earlyEvents: [[String: Any]] = []
    private var earlyEventBytes = 0
    private var retainedEventIDs: Set<UUID> = []
    private var turns: [String: String] = [:]
    private var messageStreams: [String: String] = [:]
    private var reasoningStreams: [String: String] = [:]
    private var closedMessageIDs: Set<String> = []
    private var closedReasoningIDs: Set<String> = []
    private var candidate: Root?
    private var completedRoot: Root?
    private var eventRevision = UUID()
    private var inspection: Inspection?
    struct Callback {
        let callID: String
        let command: AgentSessionManagedCommand
        var requestID: String?
        var rootMatched = false
        var turnID: String?
        var dispatched = false
        var responseRegistered = false
        var acknowledged = false
        var dismissed = false
        var telemetryStarted = false
        var telemetryCompleted = false
    }
    private var callbacks: [String: Callback] = [:]
    private var retainedCallIDs: Set<String> = []
    private var retainedRequestIDs: Set<String> = []
    private var callbackCount = 0
    private let allowsForegroundCommands: Bool
    private let workingDirectory: String

    var nextCallback: Callback? {
        guard failureReason == nil, providerInputID != nil else { return nil }
        return callbacks.values.first { $0.rootMatched && $0.requestID != nil && !$0.dispatched }
    }

    func dispatchCallback(_ callID: String) -> Bool {
        guard failureReason == nil, var current = callbacks[callID], current.rootMatched,
              current.requestID != nil, !current.dispatched else { return fail("callbackMismatch") }
        current.dispatched = true
        callbacks[callID] = current
        return true
    }

    func registerCallbackResponse(_ callID: String) -> Bool {
        guard failureReason == nil, var current = callbacks[callID], current.dispatched,
              !current.responseRegistered else { return fail("callbackMismatch") }
        current.responseRegistered = true
        callbacks[callID] = current
        return true
    }

    func acknowledgeCallback(_ callID: String) -> Bool {
        guard failureReason == nil, var current = callbacks[callID], current.responseRegistered,
              !current.acknowledged, let requestID = current.requestID,
              state.finishActivity("callback:\(requestID)") else { return fail("callbackMismatch") }
        current.acknowledged = true
        callbacks[callID] = current
        return true
    }

    var hasCompleteWorkEvidence: Bool {
        failureReason == nil && inspection == nil && completedRoot != nil && state.hasCompleteWorkEvidence
    }

    init(identity: ShepherdManagedSessionIdentity, allowsForegroundCommands: Bool = false, workingDirectory: String = "") {
        state = ShepherdManagedSessionState(identity: identity)
        self.allowsForegroundCommands = allowsForegroundCommands
        self.workingDirectory = workingDirectory
    }

    func beginInput(_ input: UUID, origin: ShepherdManagedInputOrigin) -> Bool {
        guard failureReason == nil, inspection == nil, state.beginInput(input, origin: origin) else { return false }
        inputID = input
        providerInputID = nil
        earlyEvents.removeAll()
        earlyEventBytes = 0
        turns.removeAll()
        messageStreams.removeAll()
        reasoningStreams.removeAll()
        candidate = nil
        completedRoot = nil
        callbacks.removeAll()
        callbackCount = 0
        return true
    }

    func acknowledgeInput(_ input: UUID, providerInputID: String) -> Bool {
        guard failureReason == nil else { return false }
        guard inputID == input, state.acknowledgeInput(input, providerInputID: providerInputID) else {
            return fail("inputMismatch")
        }
        self.providerInputID = providerInputID
        let buffered = earlyEvents
        earlyEvents.removeAll()
        earlyEventBytes = 0
        for event in buffered {
            guard failureReason == nil else { return false }
            process(event)
        }
        return failureReason == nil
    }

    func receive(_ bytes: Data) {
        guard failureReason == nil else { return }
        guard inputID != nil else {
            fail("rootAttributionUnavailable")
            return
        }
        let event: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let id = CopilotManagedEventMetadata.eventID(decoded) else {
                fail("invalidEvent")
                return
            }
            guard !retainedEventIDs.contains(id) else {
                fail("replayedEvent")
                return
            }
            guard retainedEventIDs.count < 16_384 else {
                fail("eventRetentionLimit")
                return
            }
            retainedEventIDs.insert(id)
            event = decoded
        } catch {
            fail("invalidEvent")
            return
        }
        eventRevision = UUID()
        state.observeProviderActivity()
        inspection = nil
        completedRoot = nil
        if event["type"] as? String == "external_tool.requested" {
            guard observeCallback(event) else { return }
        }
        if providerInputID == nil {
            guard earlyEvents.count < 64, earlyEventBytes + bytes.count <= 1_048_576 else {
                fail("earlyEventOverflow")
                return
            }
            earlyEvents.append(event)
            earlyEventBytes += bytes.count
        } else {
            process(event)
        }
    }

    func beginWorkReadback() -> UUID? {
        guard failureReason == nil, inspection == nil, let completedRoot,
              turns.isEmpty, state.outstandingActivityCount == 0 else { return nil }
        let token = UUID()
        inspection = Inspection(
            token: token, root: completedRoot, eventRevision: eventRevision, activityRevision: state.activityRevision
        )
        return token
    }

    func acceptWorkReadback(_ readback: WorkReadback, token: UUID, result: [String: Any]) -> Bool {
        guard failureReason == nil else { return false }
        guard var current = inspection, current.token == token, current.eventRevision == eventRevision,
              WorkReadback.allCases[current.acceptedSteps] == readback else {
            return fail("workReadbackMismatch")
        }
        let key: String
        switch readback {
        case .refresh: key = ""
        case .tasks: key = "tasks"
        case .schedules: key = "entries"
        case .pendingTools: key = "items"
        }
        if readback == .refresh {
            guard result.isEmpty else { return fail("workInventoryUnavailable") }
        } else {
            guard Set(result.keys) == [key], let items = result[key] as? [Any], items.isEmpty else {
                return fail("workInventoryUnavailable")
            }
        }
        current.acceptedSteps += 1
        if current.acceptedSteps == WorkReadback.allCases.count {
            inspection = nil
            guard state.recordWorkSnapshot(
                current.root.input, providerInputID: current.root.providerInputID,
                activityRevision: current.activityRevision, backgroundJobs: [], scheduledWakeups: [],
                coverageComplete: true
            ) else { return fail("workReadbackMismatch") }
        } else {
            inspection = current
        }
        return true
    }

    private func process(_ event: [String: Any]) {
        guard event["agentId"] == nil else {
            fail("foreignParticipant")
            return
        }
        guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any] else {
            fail("invalidEvent")
            return
        }
        guard data["parentToolCallId"] == nil else {
            fail("foreignParticipant")
            return
        }
        switch kind {
        case "assistant.turn_start":
            guard let turn = identifier(data["turnId"]), turns[turn] == nil,
                  let eventID = event["id"] as? String,
                  state.beginActivity(eventID, kind: .work) else {
                fail("unmatchedTurn")
                return
            }
            turns[turn] = eventID
            candidate = nil
        case "assistant.message_start":
            guard CopilotManagedEventMetadata.boolean(event["ephemeral"]) == true,
                  let message = identifier(data["messageId"]),
                  data["phase"] == nil || data["phase"] is String else {
                fail("invalidStreamingEvent")
                return
            }
            guard !closedMessageIDs.contains(message), messageStreams[message] == nil else {
                fail("replayedStream")
                return
            }
            guard turns.count == 1, let turn = turns.keys.first else {
                fail("unmatchedStream")
                return
            }
            messageStreams[message] = turn
        case "assistant.message_delta":
            guard CopilotManagedEventMetadata.boolean(event["ephemeral"]) == true,
                  let message = identifier(data["messageId"]), data["deltaContent"] is String else {
                fail("invalidStreamingEvent")
                return
            }
            guard let turn = messageStreams[message], turns[turn] != nil else {
                fail("unmatchedStream")
                return
            }
        case "assistant.reasoning_delta":
            guard CopilotManagedEventMetadata.boolean(event["ephemeral"]) == true,
                  let reasoning = identifier(data["reasoningId"]), data["deltaContent"] is String else {
                fail("invalidStreamingEvent")
                return
            }
            guard !closedReasoningIDs.contains(reasoning) else {
                fail("replayedStream")
                return
            }
            guard turns.count == 1, let turn = turns.keys.first,
                  reasoningStreams[reasoning] == nil || reasoningStreams[reasoning] == turn else {
                fail("unmatchedStream")
                return
            }
            reasoningStreams[reasoning] = turn
        case "assistant.reasoning":
            guard let reasoning = identifier(data["reasoningId"]), data["content"] is String,
                  data["rte"] == nil || CopilotManagedEventMetadata.boolean(data["rte"]) != nil else {
                fail("invalidStreamingEvent")
                return
            }
            guard !closedReasoningIDs.contains(reasoning) else {
                fail("replayedStream")
                return
            }
            guard turns.count == 1, let turn = turns.keys.first,
                  reasoningStreams[reasoning] == nil || reasoningStreams[reasoning] == turn else {
                fail("unmatchedStream")
                return
            }
            reasoningStreams.removeValue(forKey: reasoning)
            closedReasoningIDs.insert(reasoning)
        case "assistant.message":
            guard let originatingID = identifier(data["originatingMessageId"]),
                  let owner = state.inputID(matchingProviderInputID: originatingID),
                  owner == inputID, originatingID == providerInputID else {
                fail("foreignRoot")
                return
            }
            guard let turn = identifier(data["turnId"]), turns[turn] != nil,
                  let message = identifier(data["messageId"]), data["content"] is String else {
                fail("rootAttributionUnavailable")
                return
            }
            if let requests = data["toolRequests"] {
                guard let list = requests as? [[String: Any]] else {
                    fail("unsupportedCallback")
                    return
                }
                if !list.isEmpty {
                    guard allowsForegroundCommands, list.count == 1, let request = list.first,
                          Set(request.keys).isSubset(of: [
                            "toolCallId", "name", "arguments", "type", "intentionSummary", "toolTitle",
                          ]),
                          request["type"] == nil || request["type"] as? String == "function",
                          request["toolTitle"] == nil || request["toolTitle"] is String,
                          request["intentionSummary"] == nil || request["intentionSummary"] is NSNull
                            || request["intentionSummary"] is String,
                          request["name"] as? String == "cmux_run_foreground",
                          let callID = identifier(request["toolCallId"]),
                          let command = AgentSessionManagedCommand(toolArguments: request["arguments"]),
                          matchCallback(callID, command: command, fromRoot: true) else {
                        fail("unsupportedCallback")
                        return
                    }
                    callbacks[callID]?.turnID = turn
                    candidate = nil
                }
            }
            guard !closedMessageIDs.contains(message) else {
                fail("replayedStream")
                return
            }
            guard messageStreams[message] == nil || messageStreams[message] == turn else {
                fail("unmatchedStream")
                return
            }
            messageStreams.removeValue(forKey: message)
            closedMessageIDs.insert(message)
            if (data["toolRequests"] as? [Any] ?? []).isEmpty {
                guard callbacks.values.allSatisfy(\.acknowledged) else {
                    fail("callbackStillActive")
                    return
                }
                candidate = Root(input: owner, providerInputID: originatingID, turnID: turn)
            }
            if let text = data["content"] as? String, !text.isEmpty {
                projections.append(.assistant(text))
            }
        case "assistant.turn_end":
            guard let turn = identifier(data["turnId"]), let activity = turns.removeValue(forKey: turn),
                  state.finishActivity(activity) else {
                fail("unmatchedTurn")
                return
            }
            if candidate?.turnID == turn { candidate?.ended = true }
        case "session.idle":
            guard callbacks.values.allSatisfy(\.acknowledged) else {
                fail("callbackStillActive")
                return
            }
            guard data["mode"] == nil || data["mode"] as? String == "interactive",
                  data["aborted"] == nil || CopilotManagedEventMetadata.boolean(data["aborted"]) == false else {
                fail("rootNotSuccessful")
                return
            }
            guard messageStreams.isEmpty, reasoningStreams.isEmpty else {
                fail("unfinishedStream")
                return
            }
            guard let candidate, candidate.ended, turns.isEmpty,
                  state.completeRoot(
                    candidate.input, providerInputID: candidate.providerInputID, succeeded: true
                  ) else {
                fail("rootAttributionUnavailable")
                return
            }
            completedRoot = candidate
            self.candidate = nil
            projections.append(.turnComplete)
        case "assistant.idle":
            break
        case "assistant.intent":
            guard data["intent"] is String else {
                fail("invalidEvent")
                return
            }
        case "external_tool.requested":
            break
        case "external_tool.completed":
            guard Set(data.keys) == ["requestId"],
                  event["ephemeral"] == nil || CopilotManagedEventMetadata.boolean(event["ephemeral"]) == true,
                  let requestID = identifier(data["requestId"]),
                  let callID = callbacks.first(where: { $0.value.requestID == requestID })?.key,
                  var current = callbacks[callID], current.responseRegistered, !current.dismissed else {
                fail("callbackMismatch")
                return
            }
            current.dismissed = true
            callbacks[callID] = current
        case "tool.execution_start", "tool.execution_progress", "tool.execution_complete":
            receiveToolTelemetry(kind, event: event, data: data)
        default:
            fail("unsupportedEvent")
        }
    }

    private func receiveToolTelemetry(_ kind: String, event: [String: Any], data: [String: Any]) {
        guard let callID = identifier(data["toolCallId"]), var current = callbacks[callID],
              current.rootMatched,
              data["turnId"] == nil || data["turnId"] as? String == current.turnID else {
            fail("callbackMismatch")
            return
        }
        switch kind {
        case "tool.execution_start":
            guard !current.telemetryStarted, !current.responseRegistered,
                  Set(data.keys).isSubset(of: [
                    "toolCallId", "toolName", "arguments", "turnId", "model", "rte", "toolTitle", "displayVerbatim",
                  ]),
                  data["toolName"] as? String == "cmux_run_foreground",
                  AgentSessionManagedCommand(toolArguments: data["arguments"]) == current.command,
                  ["model", "toolTitle"].allSatisfy({ data[$0] == nil || data[$0] is String }),
                  ["rte", "displayVerbatim"].allSatisfy({
                    data[$0] == nil || CopilotManagedEventMetadata.boolean(data[$0]) != nil
                  }) else {
                fail("unsupportedToolTelemetry")
                return
            }
            current.telemetryStarted = true
        case "tool.execution_progress":
            guard current.telemetryStarted, !current.telemetryCompleted,
                  Set(data.keys) == ["toolCallId", "progressMessage"], data["progressMessage"] is String,
                  CopilotManagedEventMetadata.boolean(event["ephemeral"]) == true else {
                fail("unsupportedToolTelemetry")
                return
            }
        case "tool.execution_complete":
            guard current.telemetryStarted, current.responseRegistered, !current.telemetryCompleted,
                  Set(data.keys).isSubset(of: [
                    "toolCallId", "success", "result", "error", "turnId", "model", "rte", "interactionId",
                    "isUserRequested", "sandboxed",
                  ]),
                  CopilotManagedEventMetadata.boolean(data["success"]) != nil,
                  ["model", "interactionId"].allSatisfy({ data[$0] == nil || data[$0] is String }),
                  ["rte", "isUserRequested", "sandboxed"].allSatisfy({
                    data[$0] == nil || CopilotManagedEventMetadata.boolean(data[$0]) != nil
                  }) else {
                fail("unsupportedToolTelemetry")
                return
            }
            if let result = data["result"] {
                guard let result = result as? [String: Any],
                      Set(result.keys).isSubset(of: ["content", "detailedContent"]), result["content"] is String,
                      result["detailedContent"] == nil || result["detailedContent"] is String else {
                    fail("unsupportedToolTelemetry")
                    return
                }
            }
            if let error = data["error"] {
                guard let error = error as? [String: Any], Set(error.keys).isSubset(of: ["message", "code"]),
                      error["message"] is String, error["code"] == nil || error["code"] is String else {
                    fail("unsupportedToolTelemetry")
                    return
                }
            }
            current.telemetryCompleted = true
        default:
            fail("unsupportedToolTelemetry")
            return
        }
        // Provider telemetry never releases native callback activity or proves command completion.
        callbacks[callID] = current
    }

    private func matchCallback(_ callID: String, command: AgentSessionManagedCommand, fromRoot: Bool) -> Bool {
        if var current = callbacks[callID] {
            guard current.command == command, !current.acknowledged,
                  !fromRoot || !current.rootMatched else { return fail("callbackMismatch") }
            if fromRoot { current.rootMatched = true }
            callbacks[callID] = current
            return true
        }
        guard callbackCount < 8, retainedCallIDs.count < 4096, !retainedCallIDs.contains(callID),
              callbacks.values.allSatisfy(\.acknowledged) else { return fail("callbackConflict") }
        retainedCallIDs.insert(callID)
        callbackCount += 1
        callbacks[callID] = Callback(callID: callID, command: command, rootMatched: fromRoot)
        return true
    }

    private func observeCallback(_ event: [String: Any]) -> Bool {
        guard allowsForegroundCommands, event["agentId"] == nil,
              let data = event["data"] as? [String: Any],
              Set(data.keys).isSubset(of: [
                "arguments", "providerId", "requestId", "sessionId", "toolCallId", "toolName",
                "traceparent", "tracestate", "workingDirectory",
              ]),
              data["sessionId"] as? String == state.identity.providerSessionID,
              data["toolName"] as? String == "cmux_run_foreground",
              data["providerId"] == nil || data["providerId"] is NSNull,
              ["traceparent", "tracestate"].allSatisfy({ data[$0] == nil || data[$0] is String }),
              data["workingDirectory"] == nil || data["workingDirectory"] as? String == workingDirectory,
              let callID = identifier(data["toolCallId"]), let requestID = identifier(data["requestId"]),
              let command = AgentSessionManagedCommand(toolArguments: data["arguments"]),
              !retainedRequestIDs.contains(requestID), retainedRequestIDs.count < 4096,
              matchCallback(callID, command: command, fromRoot: false),
              var current = callbacks[callID], current.requestID == nil,
              state.beginActivity("callback:\(requestID)", kind: .callback) else {
            return fail("unsupportedCallback")
        }
        retainedRequestIDs.insert(requestID)
        current.requestID = requestID
        callbacks[callID] = current
        return true
    }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, ShepherdManagedSessionIdentity.validIdentifier(value) else { return nil }
        return value
    }

    @discardableResult
    private func fail(_ reason: String) -> Bool {
        if failureReason == nil { failureReason = reason }
        inspection = nil
        completedRoot = nil
        state.requireOwnerInput()
        return false
    }
}
