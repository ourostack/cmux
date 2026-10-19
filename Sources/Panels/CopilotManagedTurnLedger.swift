import CmuxControlSocket
import Foundation

/// Provider event attribution and positive work evidence, never profile qualification or input admission.
@MainActor
final class CopilotManagedTurnLedger {
    enum WorkReadback: String, CaseIterable {
        case refresh, tasks, schedules, pendingTools
    }

    private(set) var state: ShepherdManagedSessionState
    private(set) var failureReason: String?

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

    var hasCompleteWorkEvidence: Bool {
        failureReason == nil && inspection == nil && completedRoot != nil && state.hasCompleteWorkEvidence
    }

    init(identity: ShepherdManagedSessionIdentity) {
        state = ShepherdManagedSessionState(identity: identity)
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
                guard let list = requests as? [Any], list.isEmpty else {
                    fail("unsupportedCallback")
                    return
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
            candidate = Root(input: owner, providerInputID: originatingID, turnID: turn)
        case "assistant.turn_end":
            guard let turn = identifier(data["turnId"]), let activity = turns.removeValue(forKey: turn),
                  state.finishActivity(activity) else {
                fail("unmatchedTurn")
                return
            }
            if candidate?.turnID == turn { candidate?.ended = true }
        case "session.idle":
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
        case "assistant.idle":
            break
        case "assistant.intent":
            guard data["intent"] is String else {
                fail("invalidEvent")
                return
            }
        default:
            fail("unsupportedEvent")
        }
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
