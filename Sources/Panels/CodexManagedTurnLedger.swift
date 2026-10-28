import CmuxControlSocket
import CoreFoundation
import Foundation

/// Conditional closed-profile evidence only. The native owner must separately prove the fixed
/// catalog/configuration and lifetime exclusions; this ledger cannot qualify a profile or admit input.
@MainActor
final class CodexManagedTurnLedger {
    enum Projection { case assistant(String), turnComplete }
    private var projections: [Projection] = []

    func takeProjections() -> [Projection] {
        defer { projections.removeAll() }
        return failureReason == nil ? projections : []
    }

    var providerInputID: String? { root?.turnID }
    var hasPendingInspectionPage: Bool { inspection?.pendingID != nil }
    var canRequestShellPage: Bool {
        failureReason == nil && ingressID == nil && !decoder.hasPendingBytes
            && root?.finalized == true && !hasPendingInspectionPage && !hasCompleteWorkEvidence
    }

    func callbackIsSettled(_ callID: String) -> Bool { callbacks[callID]?.settled == true }
    struct Callback {
        let callID: String
        let command: AgentSessionManagedCommand
        let resultID = UUID()
        var requestID: CodexManagedStreamDecoder.RequestID?
        var dispatched = false
        var resultText: String?
        var success: Bool?
        var written = false
        var consumed = false
        var settled = false
    }

    private struct Root {
        let inputID: UUID
        let requestID: CodexManagedStreamDecoder.RequestID
        let prompt: String
        var written = false
        var response: [String: Any]?
        var turnID: String?
        var started = false
        var terminalObserved = false
        var finalized = false
    }

    private struct Inspection {
        let id: UUID
        let providerRevision: UUID
        let activityRevision: UUID
        var inventory: CodexManagedShellInventory
        var pendingID: CodexManagedStreamDecoder.RequestID?
    }

    private(set) var state: ShepherdManagedSessionState
    private(set) var failureReason: String?
    private let allowsForegroundCommands: Bool
    private var decoder = CodexManagedStreamDecoder()
    private var root: Root?
    private var ingressID: String?
    private var providerRevision = UUID()
    private var inspection: Inspection?
    private var early: [CodexManagedStreamDecoder.Message] = []
    private var earlyBytes = 0
    private var receivedBytes = 0
    private var liveItems: [String: String] = [:]
    private var lastSummaryItem: [String: Any]?
    private var callbacks: [String: Callback] = [:]
    private var callbackOrder: [String] = []
    private var retainedTurns: Set<String> = []
    private var retainedItems: Set<String> = []
    private var retainedRequests: Set<CodexManagedStreamDecoder.RequestID> = []

    var hasCompleteWorkEvidence: Bool {
        failureReason == nil && ingressID == nil && !decoder.hasPendingBytes
            && root?.finalized == true && inspection == nil && state.hasCompleteWorkEvidence
    }

    var nextCallback: Callback? {
        guard failureReason == nil, ingressID == nil, !decoder.hasPendingBytes,
              root?.started == true, root?.terminalObserved == false, !nativeCommandInFlight else { return nil }
        for id in callbackOrder {
            if let callback = callbacks[id], callback.requestID != nil, !callback.dispatched { return callback }
        }
        return nil
    }

    private var nativeCommandInFlight: Bool {
        callbacks.values.contains { $0.dispatched && $0.resultText == nil }
    }

    init(identity: ShepherdManagedSessionIdentity, allowsForegroundCommands: Bool = false) {
        state = ShepherdManagedSessionState(identity: identity)
        self.allowsForegroundCommands = allowsForegroundCommands
        if identity.provider != .codex { failureReason = "invalidScope" }
    }

    func beginInput(
        _ input: UUID, prompt: String, origin: ShepherdManagedInputOrigin = .owner
    ) -> Data? {
        guard failureReason == nil, root == nil || hasCompleteWorkEvidence else { return nil }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 65_536 else {
            fail("invalidInput")
            return nil
        }
        let id = CodexManagedStreamDecoder.RequestID.string("cmux-turn-" + input.uuidString.lowercased())
        guard let frame = frame([
            "id": id.jsonValue, "method": "turn/start",
            "params": [
                "threadId": state.identity.providerSessionID,
                "input": [["type": "text", "text": prompt, "text_elements": []] as [String: Any]],
            ],
        ]) else { return nil }
        guard state.beginInput(input, origin: origin),
              state.beginActivity(rootActivity(input), kind: .callback) else { return nil }
        root = Root(inputID: input, requestID: id, prompt: prompt)
        early.removeAll()
        earlyBytes = 0
        receivedBytes = 0
        liveItems.removeAll()
        lastSummaryItem = nil
        callbacks.removeAll()
        callbackOrder.removeAll()
        return frame
    }

    func inputWritten(_ input: UUID) -> Bool {
        guard failureReason == nil else { return false }
        guard var current = root, current.inputID == input, !current.written else {
            return fail("inputWriteMismatch")
        }
        current.written = true
        root = current
        acknowledgeIfPossible()
        finalizeIfPossible()
        return failureReason == nil
    }

    func receive(_ bytes: Data) {
        guard failureReason == nil, !bytes.isEmpty else { return }
        guard root != nil, bytes.count <= 8 * 1024 * 1024 - receivedBytes else {
            fail("unexpectedIngress")
            return
        }
        receivedBytes += bytes.count
        if ingressID == nil {
            let id = "ingress:" + UUID().uuidString.lowercased()
            guard state.beginActivity(id, kind: .callback) else {
                fail("ingressRetentionLimit")
                return
            }
            ingressID = id
        }
        do {
            for message in try decoder.append(bytes) {
                guard failureReason == nil else { return }
                process(message)
            }
        } catch {
            fail("invalidStream:\(error)")
        }
        if failureReason == nil, !decoder.hasPendingBytes, let id = ingressID {
            guard state.finishActivity(id) else {
                fail("ingressMismatch")
                return
            }
            ingressID = nil
        }
        finalizeIfPossible()
    }

    func finishStream() {
        guard failureReason == nil else { return }
        do { try decoder.finish() }
        catch {
            fail("invalidStream:\(error)")
            return
        }
        fail("streamEnded")
    }

    func dispatchCallback(_ callID: String) -> Bool {
        guard failureReason == nil else { return false }
        guard ingressID == nil, !decoder.hasPendingBytes, root?.started == true,
              root?.terminalObserved == false, var callback = callbacks[callID],
              callback.requestID != nil, !callback.dispatched else {
            return fail("commandDispatchMismatch")
        }
        guard !nativeCommandInFlight else { return false }
        guard state.beginActivity("command:" + callID, kind: .work) else { return fail("commandDispatchMismatch") }
        callback.dispatched = true
        callbacks[callID] = callback
        return true
    }

    /// Only known-complete facts from the kept native command service, never a provider result
    /// or an unknown/cancelled physical lifetime. Failed commands may still be known complete.
    func commandCompleted(_ callID: String, text: String, success: Bool) -> Data? {
        guard failureReason == nil else { return nil }
        guard root?.terminalObserved == false, var callback = callbacks[callID],
              callback.dispatched, callback.resultText == nil, let requestID = callback.requestID,
              text.utf8.count <= 262_144, state.finishActivity("command:" + callID) else {
            fail("commandCompletionMismatch")
            return nil
        }
        // A backend error fallback can equal a failed command's text; only this exact echo
        // witnesses consumption of the host-authored result for this callback.
        let resultText = "cmux-owned-result:" + callback.resultID.uuidString.lowercased() + "\n" + text
        callback.resultText = resultText
        callback.success = success
        callbacks[callID] = callback
        return frame([
            "id": requestID.jsonValue,
            "result": ["contentItems": [["type": "inputText", "text": resultText]], "success": success] as [String: Any],
        ])
    }

    func callbackResponseWritten(_ callID: String) -> Bool {
        guard failureReason == nil else { return false }
        guard var callback = callbacks[callID], callback.resultText != nil, !callback.written else {
            return fail("callbackWriteMismatch")
        }
        callback.written = true
        callbacks[callID] = callback
        settleCallbackIfPossible(callID)
        finalizeIfPossible()
        return failureReason == nil
    }

    func requestNextShellPage() -> Data? {
        guard failureReason == nil, ingressID == nil, !decoder.hasPendingBytes,
              root?.finalized == true else { return nil }
        if inspection == nil {
            guard state.outstandingActivityCount == 0 else { return nil }
            let id = UUID()
            guard state.beginActivity("inspection:" + id.uuidString.lowercased(), kind: .inspection) else {
                fail("inspectionMismatch")
                return nil
            }
            inspection = Inspection(
                id: id, providerRevision: providerRevision, activityRevision: state.activityRevision,
                inventory: CodexManagedShellInventory(
                    threadID: state.identity.providerSessionID, eventRevision: providerRevision
                )
            )
        }
        guard var current = inspection, current.providerRevision == providerRevision else {
            fail("inspectionMismatch")
            return nil
        }
        let id = CodexManagedStreamDecoder.RequestID.string("cmux-shell-" + UUID().uuidString.lowercased())
        guard let object = current.inventory.requestNextPage(id: id, currentRevision: providerRevision) else {
            fail("shellInventory:\(current.inventory.failureReason ?? "unknown")")
            return nil
        }
        current.pendingID = id
        inspection = current
        return frame(object)
    }

    func inspectionPageWritten() -> Bool {
        guard failureReason == nil else { return false }
        guard var current = inspection, let id = current.pendingID,
              current.inventory.pageWritten(id: id, currentRevision: providerRevision) else {
            return fail("inspectionWriteMismatch")
        }
        if !current.inventory.hasPendingPage { current.pendingID = nil }
        inspection = current
        finalizeIfPossible()
        return failureReason == nil
    }

    private func process(_ message: CodexManagedStreamDecoder.Message) {
        guard var current = root else {
            fail("rootUnavailable")
            return
        }
        if message.kind == .response || message.kind == .error {
            if message.id == current.requestID {
                guard message.kind == .response, current.turnID == nil, current.response == nil,
                      let result = message.object["result"] as? [String: Any] else {
                    fail("rootResponseMismatch")
                    return
                }
                current.response = result
                root = current
                acknowledgeIfPossible()
            } else if var observed = inspection, message.id == observed.pendingID {
                guard observed.inventory.receive(message, currentRevision: providerRevision) else {
                    fail("shellInventory:\(observed.inventory.failureReason ?? "unknown")")
                    return
                }
                if !observed.inventory.hasPendingPage { observed.pendingID = nil }
                inspection = observed
            } else {
                fail("unexpectedResponse")
            }
            return
        }
        if current.turnID == nil {
            guard early.count < 64, message.wireByteCount <= 1_048_576 - earlyBytes else {
                fail("earlyEventOverflow")
                return
            }
            early.append(message)
            earlyBytes += message.wireByteCount
            return
        }
        processBound(message)
    }

    private func acknowledgeIfPossible() {
        guard failureReason == nil, var current = root, current.written,
              let response = current.response else { return }
        guard Set(response.keys) == ["turn"], let turn = response["turn"] as? [String: Any],
              let id = validTurn(turn, status: "inProgress"),
              !retainedTurns.contains(id), retainedTurns.count < 4096,
              state.acknowledgeInput(current.inputID, providerInputID: id),
              state.finishActivity(rootActivity(current.inputID)) else {
            fail("rootAcknowledgementMismatch")
            return
        }
        retainedTurns.insert(id)
        current.turnID = id
        current.response = nil
        root = current
        let buffered = early
        early.removeAll()
        earlyBytes = 0
        for message in buffered {
            guard failureReason == nil else { return }
            processBound(message)
        }
    }

    private func processBound(_ message: CodexManagedStreamDecoder.Message) {
        guard inspection == nil, root?.terminalObserved == false else {
            fail("activityAfterRoot")
            return
        }
        providerRevision = UUID()
        state.observeProviderActivity()
        guard let method = message.object["method"] as? String,
              let params = message.object["params"] as? [String: Any],
              params["threadId"] as? String == state.identity.providerSessionID else {
            fail("foreignActivity")
            return
        }
        if message.kind == .request {
            observeCallback(message, method: method, params: params)
            return
        }
        guard message.kind == .notification else {
            fail("unexpectedEnvelope")
            return
        }
        if method == "turn/started" || method == "turn/completed" {
            guard var current = root, Set(params.keys) == ["threadId", "turn"],
                  let turn = params["turn"] as? [String: Any],
                  validTurn(turn, status: method == "turn/started" ? "inProgress" : "completed") == current.turnID else {
                fail("rootLifecycleMismatch")
                return
            }
            if method == "turn/started" {
                guard !current.started else {
                    fail("duplicateRootStart")
                    return
                }
                current.started = true
            } else {
                guard current.started, liveItems.isEmpty,
                      callbacks.values.allSatisfy({ $0.resultText != nil && $0.consumed }) else {
                    fail("workOutstandingAtRoot")
                    return
                }
                current.terminalObserved = true
            }
            root = current
        } else {
            guard root?.started == true, params["turnId"] as? String == root?.turnID else {
                fail("foreignTurn")
                return
            }
            switch method {
            case "item/started", "item/completed":
                observeItem(method: method, params: params)
            case "item/agentMessage/delta", "item/plan/delta":
                let kind = method == "item/plan/delta" ? "plan" : "agentMessage"
                guard Set(params.keys) == ["threadId", "turnId", "itemId", "delta"],
                      let id = params["itemId"] as? String, liveItems[id] == kind,
                      params["delta"] is String else {
                    fail("deltaMismatch")
                    return
                }
            case "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded", "item/reasoning/textDelta":
                let index = method == "item/reasoning/textDelta" ? "contentIndex" : "summaryIndex"
                let hasDelta = method != "item/reasoning/summaryPartAdded"
                var keys: Set<String> = ["threadId", "turnId", "itemId", index]
                if hasDelta { keys.insert("delta") }
                guard Set(params.keys) == keys, let id = params["itemId"] as? String,
                      liveItems[id] == "reasoning", nonnegativeInteger(params[index]),
                      !hasDelta || params["delta"] is String else {
                    fail("reasoningProgressMismatch")
                    return
                }
            default:
                fail("unsupportedEvent")
            }
        }
    }

    private func observeItem(method: String, params: [String: Any]) {
        let started = method == "item/started"
        let timestamp = started ? "startedAtMs" : "completedAtMs"
        guard Set(params.keys) == ["threadId", "turnId", "item", timestamp],
              nonnegativeInteger(params[timestamp]),
              let item = params["item"] as? [String: Any], let id = item["id"] as? String,
              ShepherdManagedSessionIdentity.validIdentifier("item:" + id),
              let kind = item["type"] as? String else {
            fail("itemMismatch")
            return
        }
        if started {
            guard !retainedItems.contains(id), retainedItems.count < 16_384,
                  liveItems.count < 256, state.beginActivity("item:" + id, kind: .callback) else {
                fail("itemRetentionMismatch")
                return
            }
            retainedItems.insert(id)
            liveItems[id] = kind
        } else if liveItems[id] != kind {
            fail("itemLifecycleMismatch")
            return
        }
        if kind == "dynamicToolCall" {
            guard allowsForegroundCommands, validToolItem(item),
                  let command = AgentSessionManagedCommand(toolArguments: item["arguments"]) else {
                fail("unsupportedTool")
                return
            }
            if started {
                guard item["status"] as? String == "inProgress", item["contentItems"] is NSNull,
                      item["success"] is NSNull, item["durationMs"] is NSNull else {
                    fail("toolStartMismatch")
                    return
                }
                callbacks[id] = Callback(callID: id, command: command)
                callbackOrder.append(id)
            } else {
                guard var callback = callbacks[id], callback.command == command, !callback.consumed,
                      let text = callback.resultText, let success = callback.success,
                      boolean(item["success"]) == success,
                      item["status"] as? String == (success ? "completed" : "failed"),
                      let content = item["contentItems"] as? [[String: Any]], content.count == 1,
                      Set(content[0].keys) == ["type", "text"],
                      content[0]["type"] as? String == "inputText", content[0]["text"] as? String == text,
                      optionalNonnegativeInteger(item["durationMs"]) else {
                    fail("toolConsumptionMismatch")
                    return
                }
                callback.consumed = true
                callbacks[id] = callback
                liveItems.removeValue(forKey: id)
                settleCallbackIfPossible(id)
            }
        } else {
            guard validPassiveItem(item, kind: kind) else {
                fail("unsupportedItem")
                return
            }
            if !started {
                if kind == "agentMessage", let text = item["text"] as? String {
                    projections.append(.assistant(text))
                }
                if kind == "agentMessage", let text = item["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   item["phase"] == nil || item["phase"] is NSNull || item["phase"] as? String == "final_answer" {
                    lastSummaryItem = item
                }
                liveItems.removeValue(forKey: id)
                guard state.finishActivity("item:" + id) else {
                    fail("itemCompletionMismatch")
                    return
                }
            }
        }
    }

    private func observeCallback(
        _ message: CodexManagedStreamDecoder.Message, method: String, params: [String: Any]
    ) {
        guard allowsForegroundCommands, method == "item/tool/call", root?.started == true,
              Set(params.keys) == ["threadId", "turnId", "callId", "namespace", "tool", "arguments"],
              params["turnId"] as? String == root?.turnID, params["namespace"] is NSNull,
              params["tool"] as? String == "cmux_run_foreground",
              let id = params["callId"] as? String, var callback = callbacks[id],
              liveItems[id] == "dynamicToolCall", callback.requestID == nil,
              AgentSessionManagedCommand(toolArguments: params["arguments"]) == callback.command,
              let requestID = message.id, retainedRequests.count < 16_384,
              retainedRequests.insert(requestID).inserted,
              state.beginActivity(callbackActivity(requestID), kind: .callback) else {
            fail("callbackMismatch")
            return
        }
        callback.requestID = requestID
        callbacks[id] = callback
    }

    private func settleCallbackIfPossible(_ id: String) {
        guard failureReason == nil, var callback = callbacks[id],
              callback.written, callback.consumed, !callback.settled,
              let requestID = callback.requestID else { return }
        guard state.finishActivity("item:" + id), state.finishActivity(callbackActivity(requestID)) else {
            fail("callbackSettlementMismatch")
            return
        }
        callback.settled = true
        callbacks[id] = callback
    }

    private func finalizeIfPossible() {
        guard failureReason == nil, ingressID == nil, !decoder.hasPendingBytes, var current = root else { return }
        if current.terminalObserved && !current.finalized
            && callbacks.values.allSatisfy(\.settled) && state.outstandingActivityCount == 0 {
            guard let turnID = current.turnID,
                  state.completeRoot(current.inputID, providerInputID: turnID, succeeded: true) else {
                fail("rootCompletionMismatch")
                return
            }
            current.finalized = true
            root = current
        }
        guard let observed = inspection, observed.inventory.isComplete else { return }
        guard observed.providerRevision == providerRevision, observed.inventory.hasEmptyCompleteSnapshot,
              observed.pendingID == nil, current.finalized, let turnID = current.turnID,
              state.outstandingActivityCount == 1,
              state.finishActivity("inspection:" + observed.id.uuidString.lowercased()),
              state.recordWorkSnapshot(
                current.inputID, providerInputID: turnID, activityRevision: observed.activityRevision,
                backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
              ) else {
            fail("workCoverageUnavailable")
            return
        }
        inspection = nil
        projections.append(.turnComplete)
    }

    private func validTurn(_ value: [String: Any], status: String) -> String? {
        guard Set(value.keys) == ["id", "items", "itemsView", "status", "error", "startedAt", "completedAt", "durationMs"],
              let id = value["id"] as? String, ShepherdManagedSessionIdentity.validIdentifier(id),
              value["status"] as? String == status, value["error"] is NSNull,
              let items = value["items"] as? [Any],
              optionalNonnegativeInteger(value["startedAt"]), optionalNonnegativeInteger(value["completedAt"]),
              optionalNonnegativeInteger(value["durationMs"]) else { return nil }
        if status == "completed" {
            guard validTerminalItems(items, view: value["itemsView"]) else { return nil }
        } else {
            guard items.isEmpty, value["itemsView"] as? String == "notLoaded" else { return nil }
        }
        return id
    }

    private func validTerminalItems(_ items: [Any], view: Any?) -> Bool {
        guard let expected = lastSummaryItem else {
            return items.isEmpty && view as? String == "notLoaded"
        }
        guard view as? String == "summary", items.count == 1,
              let summary = items[0] as? [String: Any],
              summary["type"] as? String == "agentMessage",
              validPassiveItem(summary, kind: "agentMessage") else { return false }
        return NSDictionary(dictionary: summary).isEqual(to: expected)
    }

    private func validToolItem(_ item: [String: Any]) -> Bool {
        Set(item.keys) == ["type", "id", "namespace", "tool", "arguments", "status", "contentItems", "success", "durationMs"]
            && item["namespace"] is NSNull && item["tool"] as? String == "cmux_run_foreground"
    }

    private func validPassiveItem(_ item: [String: Any], kind: String) -> Bool {
        switch kind {
        case "agentMessage":
            return Set(item.keys).isSubset(of: [
                "type", "id", "text", "phase", "memoryCitation", "delivery", "questions",
            ]) && item["text"] is String
                && validPhase(item["phase"]) && validMemoryCitation(item["memoryCitation"])
                && (item["delivery"] == nil || item["delivery"] is NSNull)
                && (item["questions"] == nil || item["questions"] is NSNull)
        case "plan":
            return Set(item.keys) == ["type", "id", "text"] && item["text"] is String
        case "reasoning":
            return Set(item.keys) == ["type", "id", "summary", "content"]
                && item["summary"] is [String] && item["content"] is [String]
        case "contextCompaction":
            return Set(item.keys) == ["type", "id"]
        case "userMessage":
            guard Set(item.keys) == ["type", "id", "clientId", "content"], item["clientId"] is NSNull,
                  let content = item["content"] as? [[String: Any]], content.count == 1,
                  Set(content[0].keys) == ["type", "text", "text_elements"],
                  content[0]["type"] as? String == "text", content[0]["text"] as? String == root?.prompt,
                  let elements = content[0]["text_elements"] as? [Any], elements.isEmpty else { return false }
            return true
        default:
            return false
        }
    }

    private func validPhase(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        guard let phase = value as? String else { return false }
        return phase == "commentary" || phase == "final_answer"
    }

    private func validMemoryCitation(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        guard let citation = value as? [String: Any], Set(citation.keys) == ["entries", "threadIds"],
              citation["threadIds"] is [String], let entries = citation["entries"] as? [[String: Any]] else {
            return false
        }
        return entries.allSatisfy { entry in
            Set(entry.keys) == ["path", "lineStart", "lineEnd", "note"]
                && entry["path"] is String && entry["note"] is String
                && unsigned32(entry["lineStart"]) && unsigned32(entry["lineEnd"])
        }
    }

    private func unsigned32(_ value: Any?) -> Bool {
        guard case .integer(let number)? = CodexManagedStreamDecoder.RequestID(jsonValue: value) else { return false }
        return number >= 0 && number <= UInt32.max
    }

    private func nonnegativeInteger(_ value: Any?) -> Bool {
        guard case .integer(let number)? = CodexManagedStreamDecoder.RequestID(jsonValue: value) else { return false }
        return number >= 0
    }

    private func optionalNonnegativeInteger(_ value: Any?) -> Bool {
        value is NSNull || nonnegativeInteger(value)
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func rootActivity(_ input: UUID) -> String { "root:" + input.uuidString.lowercased() }

    private func callbackActivity(_ id: CodexManagedStreamDecoder.RequestID) -> String {
        switch id {
        case .string(let value): "rpc:s:" + value
        case .integer(let value): "rpc:i:" + String(value)
        }
    }

    private func frame(_ object: [String: Any]) -> Data? {
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            guard data.count < 1_048_576 else {
                fail("frameTooLarge")
                return nil
            }
            data.append(0x0A)
            return data
        } catch {
            fail("unencodableFrame")
            return nil
        }
    }

    @discardableResult
    private func fail(_ reason: String) -> Bool {
        if failureReason == nil { failureReason = reason }
        state.requireOwnerInput()
        return false
    }
}
