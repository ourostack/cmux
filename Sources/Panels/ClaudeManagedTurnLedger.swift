import CmuxControlSocket
import CoreFoundation
import Foundation

/// Conditional closed-profile work evidence, never provider qualification or input admission.
@MainActor
final class ClaudeManagedTurnLedger {
    private(set) var state: ShepherdManagedSessionState
    private(set) var failureReason: String?
    private var decoder = ClaudeManagedStreamDecoder()
    private let workingDirectory: String
    private var inputID: UUID?
    private var prompt = ""
    private var written = false
    private var replayed = false
    private var acknowledged = false
    private var promptID: UUID?
    private var resultObserved = false
    private var idleObserved = false
    private var retainedEvents: Set<UUID> = []
    private var retainedRequests: Set<String> = []
    private var retainedLifecycles: Set<String> = []
    private var retainedPrompts: Set<UUID> = []
    private var callbacks: [Hook: Callback] = [:]
    private var lifecycles: [Hook: Lifecycle] = [:]

    private enum Hook: String, CaseIterable {
        case submit = "UserPromptSubmit", stop = "Stop"
        var route: String { "cmux-" + rawValue }
    }

    private struct Callback {
        let requestID: String
        let inputID: UUID
        var written = false
        var settled = false
    }

    private struct Lifecycle {
        let id: String
        let inputID: UUID
        let name: String
        var settled = false
    }

    var hasCompleteWorkEvidence: Bool {
        failureReason == nil && !decoder.hasPendingBytes && idleObserved && state.hasCompleteWorkEvidence
    }

    init(identity: ShepherdManagedSessionIdentity, workingDirectory: String) {
        state = ShepherdManagedSessionState(identity: identity)
        self.workingDirectory = workingDirectory
        if identity.provider != .claude || workingDirectory.isEmpty { failureReason = "invalidScope" }
    }

    func beginInput(_ input: UUID, prompt: String) -> Bool {
        guard failureReason == nil, inputID == nil || hasCompleteWorkEvidence,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard state.beginInput(input, origin: .owner) else { return fail("inputMismatch") }
        inputID = input
        self.prompt = prompt
        written = false
        replayed = false
        acknowledged = false
        promptID = nil
        resultObserved = false
        idleObserved = false
        callbacks.removeAll()
        lifecycles.removeAll()
        return true
    }

    func inputWritten(_ input: UUID) -> Bool {
        guard failureReason == nil else { return false }
        guard inputID == input, !written else { return fail("inputWriteMismatch") }
        written = true
        return acknowledgeIfPossible()
    }

    /// Local full-write admission only; the callback remains outstanding until its producer witness.
    func callbackResponseWritten(_ requestID: String) -> Bool {
        guard failureReason == nil else { return false }
        guard let kind = callbacks.first(where: { $0.value.requestID == requestID })?.key,
              var callback = callbacks[kind], callback.inputID == inputID, !callback.written else {
            return fail("callbackWriteMismatch")
        }
        callback.written = true
        callbacks[kind] = callback
        return true
    }

    func beginHostWork(_ workID: String) -> Bool {
        guard failureReason == nil, inputID != nil, !resultObserved, !idleObserved else {
            return fail("hostWorkMismatch")
        }
        guard state.beginActivity("work:" + workID, kind: .work) else { return fail("hostWorkMismatch") }
        return true
    }

    func finishHostWork(_ workID: String) -> Bool {
        guard failureReason == nil else { return false }
        guard state.finishActivity("work:" + workID) else { return fail("hostWorkMismatch") }
        return true
    }

    func receive(_ bytes: Data) {
        guard failureReason == nil else { return }
        guard !bytes.isEmpty else { return }
        guard inputID != nil, !idleObserved else {
            fail("unexpectedActivity")
            return
        }
        state.observeProviderActivity()
        do {
            for event in try decoder.append(bytes) {
                guard failureReason == nil else { return }
                guard inputID != nil, !idleObserved else {
                    fail("unexpectedActivity")
                    return
                }
                state.observeProviderActivity()
                process(event)
            }
        } catch {
            fail("invalidStream:\(error)")
        }
    }

    private func process(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "control_request":
            observeCallback(event)
        case "user":
            guard registerEvent(event), !replayed,
                  boolean(event["isReplay"]) == true, uuid(event["uuid"]) == inputID,
                  event["parent_tool_use_id"] is NSNull,
                  event["agent_id"] == nil, event["origin"] == nil,
                  event["isSynthetic"] == nil || boolean(event["isSynthetic"]) == false,
                  let message = event["message"] as? [String: Any],
                  message["role"] as? String == "user", message["content"] as? String == prompt else {
                fail("replayMismatch")
                return
            }
            replayed = true
            _ = acknowledgeIfPossible()
        case "result":
            guard registerEvent(event), !resultObserved,
                  event["subtype"] as? String == "success", boolean(event["is_error"]) == false,
                  let ids = event["user_message_uuids"] as? [String], ids.count == 1,
                  uuid(ids[0]) == inputID,
                  event["user_message_uuid"] == nil || uuid(event["user_message_uuid"]) == inputID,
                  let queued = event["queued_turn_count"] as? NSNumber,
                  CFGetTypeID(queued) != CFBooleanGetTypeID(), queued == 0,
                  event["agent_id"] == nil, event["origin"] == nil,
                  event["parent_tool_use_id"] == nil,
                  event["resume_reason"] == nil, event["local_command"] == nil,
                  event["deferred_tool_use"] == nil else {
                fail("rootMismatch")
                return
            }
            resultObserved = true
        case "system":
            observeSystem(event)
        default:
            fail("unsupportedEvent")
        }
    }

    private func observeCallback(_ event: [String: Any]) {
        guard let inputID,
              Set(event.keys) == ["type", "request_id", "request"],
              let requestID = event["request_id"] as? String,
              ShepherdManagedSessionIdentity.validIdentifier(requestID),
              !retainedRequests.contains(requestID), retainedRequests.count < 16_384,
              let request = event["request"] as? [String: Any],
              Set(request.keys) == ["subtype", "callback_id", "input"],
              request["subtype"] as? String == "hook_callback",
              let input = request["input"] as? [String: Any],
              let name = input["hook_event_name"] as? String, let kind = Hook(rawValue: name),
              request["callback_id"] as? String == kind.route, callbacks[kind] == nil,
              input["session_id"] as? String == state.identity.providerSessionID,
              input["cwd"] as? String == workingDirectory,
              let transcript = input["transcript_path"] as? String, transcript.hasPrefix("/"),
              input["agent_id"] == nil, input["agent_type"] == nil,
              let providerPrompt = uuid(input["prompt_id"]) else {
            fail("callbackMismatch")
            return
        }
        let baseKeys: Set<String> = [
            "session_id", "transcript_path", "cwd", "prompt_id", "permission_mode", "effort", "hook_event_name",
        ]
        let hookKeys: Set<String> = kind == .submit
            ? ["prompt", "source", "session_title"]
            : ["stop_hook_active", "last_assistant_message", "background_tasks", "session_crons"]
        guard Set(input.keys).isSubset(of: baseKeys.union(hookKeys)) else {
            fail("callbackMismatch")
            return
        }
        if kind == .submit {
            guard promptID == nil, !retainedPrompts.contains(providerPrompt), retainedPrompts.count < 4_096,
                  input["source"] as? String == "sdk", input["prompt"] as? String == prompt else {
                fail("promptMismatch")
                return
            }
            promptID = providerPrompt
            retainedPrompts.insert(providerPrompt)
        } else {
            guard providerPrompt == promptID,
                  boolean(input["stop_hook_active"]) == false,
                  let tasks = input["background_tasks"] as? [Any], tasks.isEmpty,
                  let crons = input["session_crons"] as? [Any], crons.isEmpty else {
                fail("workCoverageUnavailable")
                return
            }
        }
        retainedRequests.insert(requestID)
        callbacks[kind] = Callback(requestID: requestID, inputID: inputID)
        guard state.beginActivity("callback:" + requestID, kind: .callback) else {
            fail("callbackMismatch")
            return
        }
        _ = acknowledgeIfPossible()
    }

    private func observeSystem(_ event: [String: Any]) {
        guard registerEvent(event) else { return }
        switch event["subtype"] as? String {
        case "hook_started":
            guard let inputID,
                  Set(event.keys) == ["type", "subtype", "uuid", "session_id", "hook_id", "hook_name", "hook_event"],
                  let name = event["hook_event"] as? String, let kind = Hook(rawValue: name),
                  lifecycles[kind] == nil,
                  let id = event["hook_id"] as? String, ShepherdManagedSessionIdentity.validIdentifier(id),
                  !retainedLifecycles.contains(id), retainedLifecycles.count < 16_384,
                  let hookName = event["hook_name"] as? String, !hookName.isEmpty else {
                fail("lifecycleMismatch")
                return
            }
            retainedLifecycles.insert(id)
            lifecycles[kind] = Lifecycle(id: id, inputID: inputID, name: hookName)
        case "hook_response":
            let requiredKeys: Set<String> = [
                "type", "subtype", "uuid", "session_id", "hook_id", "hook_name", "hook_event",
                "outcome", "output", "stdout", "stderr",
            ]
            guard Set(event.keys).isSubset(of: requiredKeys.union(["exit_code"])),
                  event["exit_code"] == nil || isZeroNumber(event["exit_code"]),
                  let name = event["hook_event"] as? String, let kind = Hook(rawValue: name),
                  var lifecycle = lifecycles[kind], lifecycle.inputID == inputID, !lifecycle.settled,
                  event["hook_id"] as? String == lifecycle.id,
                  event["hook_name"] as? String == lifecycle.name,
                  event["outcome"] as? String == "success",
                  event["output"] is String, event["stdout"] is String, event["stderr"] is String,
                  var callback = callbacks[kind], callback.inputID == inputID,
                  callback.written, !callback.settled else {
                fail("callbackUnsettled")
                return
            }
            guard state.finishActivity("callback:" + callback.requestID) else {
                fail("callbackMismatch")
                return
            }
            lifecycle.settled = true
            callback.settled = true
            lifecycles[kind] = lifecycle
            callbacks[kind] = callback
        case "session_state_changed":
            guard Set(event.keys) == ["type", "subtype", "state", "uuid", "session_id"],
                  event["state"] as? String == "idle" else {
                fail("rootNotSuccessful")
                return
            }
            guard !decoder.hasPendingBytes, acknowledged, resultObserved,
                  Hook.allCases.allSatisfy({ callbacks[$0]?.settled == true && lifecycles[$0]?.settled == true }),
                  state.outstandingActivityCount == 0, let inputID, let promptID else {
                fail("prematureIdle")
                return
            }
            guard state.completeRoot(inputID, providerInputID: promptID.uuidString.lowercased(), succeeded: true),
                  state.recordWorkSnapshot(
                    inputID, providerInputID: promptID.uuidString.lowercased(),
                    activityRevision: state.activityRevision,
                    backgroundJobs: [], scheduledWakeups: [], coverageComplete: true
                  ) else {
                fail("workCoverageUnavailable")
                return
            }
            idleObserved = true
        default:
            fail("unsupportedEvent")
        }
    }

    private func acknowledgeIfPossible() -> Bool {
        guard !acknowledged, written, replayed, let inputID, let promptID else { return true }
        guard state.acknowledgeInput(inputID, providerInputID: promptID.uuidString.lowercased()) else {
            return fail("inputMismatch")
        }
        acknowledged = true
        return true
    }

    private func registerEvent(_ event: [String: Any]) -> Bool {
        guard event["session_id"] as? String == state.identity.providerSessionID,
              event["agent_id"] == nil, let id = uuid(event["uuid"]),
              !retainedEvents.contains(id), retainedEvents.count < 16_384 else {
            return fail("eventMismatch")
        }
        retainedEvents.insert(id)
        return true
    }

    private func uuid(_ value: Any?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func isZeroNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number == 0
    }

    @discardableResult
    private func fail(_ reason: String) -> Bool {
        if failureReason == nil { failureReason = reason }
        state.observeProviderActivity()
        return false
    }
}
