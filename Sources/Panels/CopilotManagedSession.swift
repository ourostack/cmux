import CmuxControlSocket
import CoreFoundation
import Foundation

/// Private protocol startup only. No automatic input is admitted before effective readbacks.
@MainActor
final class CopilotManagedSession {
    enum Phase: String {
        case idle, connecting, creating, configuring, awaitingReadback, configurationObserved, held
    }

    let sessionID = UUID().uuidString.lowercased()
    private(set) var phase: Phase = .idle
    private(set) var holdReason: String?
    private(set) var bufferedEvents: [Data] = []
    private(set) var diagnostics = Data()
    private(set) var closeFailures: [String] = []

    private enum Method {
        case connect, create, options
        case readback(CopilotManagedConfiguration.Readback)

        var name: String {
            switch self {
            case .connect: "connect"
            case .create: "session.create"
            case .options: "session.options.update"
            case .readback(let readback): readback.method
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
    private var verifiedReadbacks: Set<CopilotManagedConfiguration.Readback> = []

    init(
        lifetime: AgentSessionManagedSession, takingOwnershipOf input: FileHandle,
        workingDirectory: String
    ) throws {
        self.lifetime = lifetime
        self.writer = try ShepherdManagedPipeWriter(takingOwnershipOf: input)
        self.workingDirectory = workingDirectory
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
              let event = params["event"] as? [String: Any],
              event["type"] as? String == "session.start" else {
            hold("unsupportedNotification")
            return
        }
        guard params["sessionId"] as? String == sessionID,
              phase == .creating || phase == .configuring || phase == .awaitingReadback
                || phase == .configurationObserved else {
            hold("sessionMismatch")
            return
        }
        guard validateStartupEvent(event) else { return }
        guard startupEventID == nil else {
            hold("duplicateStartupEvent")
            return
        }
        guard bufferedEvents.count < 64, bufferedEventBytes + body.count <= 1_048_576 else {
            hold("eventBufferOverflow")
            return
        }
        bufferedEvents.append(body)
        bufferedEventBytes += body.count
        startupEventID = (event["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func validateStartupEvent(_ event: [String: Any]) -> Bool {
        guard let textID = event["id"] as? String, let eventID = UUID(uuidString: textID),
              eventID.uuid.6 & 0xf0 == 0x40, eventID.uuid.8 & 0xc0 == 0x80,
              event["parentId"] is NSNull,
              let timestamp = event["timestamp"] as? String, Self.isTimestamp(timestamp),
              let data = event["data"] as? [String: Any],
              data["copilotVersion"] as? String == "1.0.98",
              let producer = data["producer"] as? String, !producer.isEmpty,
              let started = data["startTime"] as? String, Self.isTimestamp(started),
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

    private static func isTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
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
        pending.removeValue(forKey: id)
        timeoutTask?.cancel()
        switch registered.method {
        case .connect:
            guard Self.isTrue(response["ok"]),
                  response["protocolVersion"] as? Int == 3,
                  response["version"] as? String == "1.0.98" else {
                hold("incompatiblePeer")
                return
            }
            phase = .creating
            request(.create, params: CopilotManagedConfiguration.createParameters(
                sessionID: sessionID, workingDirectory: workingDirectory
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
            request(.options, params: CopilotManagedConfiguration.optionParameters(sessionID: sessionID))
        case .options:
            guard Self.isTrue(response["success"]), response["pluginHookCount"] as? Int == 0 else {
                hold("configurationRefused")
                return
            }
            guard startupEventID != nil else {
                hold("startupEventUnavailable")
                return
            }
            phase = .awaitingReadback
            requestReadback(.agents)
        case .readback(let readback):
            guard phase == .awaitingReadback, readback.accepts(response),
                  verifiedReadbacks.insert(readback).inserted else {
                hold("configurationMismatch")
                return
            }
            let steps = CopilotManagedConfiguration.Readback.allCases
            if let next = steps.first(where: { !verifiedReadbacks.contains($0) }) {
                requestReadback(next)
            } else {
                phase = .configurationObserved
            }
        }
    }

    private func requestReadback(_ readback: CopilotManagedConfiguration.Readback) {
        var params: [String: Any] = ["sessionId": sessionID]
        if readback == .agents { params["includeBuiltInAgents"] = true }
        request(.readback(readback), params: params)
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private func hold(_ reason: String) {
        guard phase != .held else { return }
        phase = .held
        holdReason = reason
        pending.removeAll()
        writeTask?.cancel()
        timeoutTask?.cancel()
        do { try writer.close() } catch { closeFailures.append("stdin: \(error)") }
        do { try lifetime.abandon() } catch { closeFailures.append("output: \(error)") }
    }
}
