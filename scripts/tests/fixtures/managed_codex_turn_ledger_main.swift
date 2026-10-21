import CmuxControlSocket
import Foundation

@main
struct ManagedCodexTurnLedgerFixture {
    @MainActor static func main() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = request["actions"] as? [[String: Any]],
              let identity = ShepherdManagedSessionIdentity(
                hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
                backendPID: 123, backendStartSeconds: 1, backendStartMicroseconds: 0,
                provider: .codex, providerSessionID: "controlled-thread", surfaceGeneration: 1,
                executableSHA256: String(repeating: "a", count: 64),
                profileSHA256: String(repeating: "b", count: 64)
              ) else { throw CocoaError(.coderInvalidValue) }
        let ledger = CodexManagedTurnLedger(identity: identity, allowsForegroundCommands: request["coding"] as? Bool == true)
        let outgoing = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: outgoing.fileHandleForWriting)
        let incoming = Pipe()
        var incomingEnded = false
        var inputFrames: [UUID: Data] = [:]
        var callbackFrames: [String: Data] = [:]
        var inspectionFrame: Data?
        var output: [[String: Any]] = []
        for action in actions {
            var frame: Data?
            var unissuedReplyProbe = false
            let accepted: Bool
            switch action["op"] as? String {
            case "begin":
                guard let value = action["inputID"] as? String, let id = UUID(uuidString: value),
                      let prompt = action["prompt"] as? String else { throw CocoaError(.coderInvalidValue) }
                frame = ledger.beginInput(
                    id, prompt: prompt, origin: action["origin"] as? String == "supervisor" ? .supervisor : .owner
                )
                if let frame { inputFrames[id] = frame }
                accepted = frame != nil
            case "written":
                guard let value = action["inputID"] as? String, let id = UUID(uuidString: value),
                      let bytes = inputFrames[id] else { throw CocoaError(.coderInvalidValue) }
                accepted = try await write(bytes, action: action, writer: writer, reader: outgoing.fileHandleForReading)
                    && ledger.inputWritten(id)
            case "message", "raw":
                let bytes: Data
                if let callID = action["echoCallID"] as? String {
                    guard let response = callbackFrames[callID],
                          let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                          let result = object["result"] as? [String: Any],
                          var event = action["message"] as? [String: Any],
                          var params = event["params"] as? [String: Any],
                          var item = params["item"] as? [String: Any] else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    item["contentItems"] = result["contentItems"]
                    params["item"] = item
                    event["params"] = params
                    bytes = try JSONSerialization.data(withJSONObject: event) + Data([0x0A])
                } else if let wire = action["wire"] as? String {
                    bytes = Data(wire.utf8)
                } else if let value = action["bytes"] as? String, let value = Data(base64Encoded: value) {
                    bytes = value
                } else {
                    throw CocoaError(.coderInvalidValue)
                }
                try deliver(bytes, from: incoming, to: ledger)
                accepted = ledger.failureReason == nil
            case "dispatch":
                guard let id = action["callID"] as? String else { throw CocoaError(.coderInvalidValue) }
                accepted = ledger.dispatchCallback(id)
            case "commandCompleted":
                guard let id = action["callID"] as? String, let text = action["text"] as? String,
                      let success = action["success"] as? Bool else { throw CocoaError(.coderInvalidValue) }
                frame = ledger.commandCompleted(id, text: text, success: success)
                if let frame { callbackFrames[id] = frame }
                accepted = frame != nil
            case "callbackWritten":
                guard let id = action["callID"] as? String, let bytes = callbackFrames[id] else {
                    throw CocoaError(.coderInvalidValue)
                }
                accepted = try await write(bytes, action: action, writer: writer, reader: outgoing.fileHandleForReading)
                    && ledger.callbackResponseWritten(id)
            case "inspect":
                frame = ledger.requestNextShellPage()
                inspectionFrame = frame
                accepted = frame != nil
            case "inspectionWritten":
                if let bytes = inspectionFrame {
                    accepted = try await write(bytes, action: action, writer: writer, reader: outgoing.fileHandleForReading)
                        && ledger.inspectionPageWritten()
                } else {
                    accepted = ledger.inspectionPageWritten()
                }
            case "inspectionResponse":
                let id: Any
                if let requestBytes = inspectionFrame,
                   let object = try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any],
                   let requestID = object["id"] {
                    id = requestID
                } else {
                    guard ledger.failureReason != nil else { throw CocoaError(.coderInvalidValue) }
                    id = "unissued-after-hold"
                    unissuedReplyProbe = true
                }
                guard let result = action["result"] else { throw CocoaError(.coderInvalidValue) }
                var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
                bytes.append(0x0A)
                try deliver(bytes, from: incoming, to: ledger)
                accepted = ledger.failureReason == nil
            case "eof":
                try incoming.fileHandleForWriting.close()
                incomingEnded = true
                guard try incoming.fileHandleForReading.read(upToCount: 1) == nil else {
                    throw CocoaError(.fileReadUnknown)
                }
                ledger.finishStream()
                accepted = false
            default:
                throw CocoaError(.coderInvalidValue)
            }
            let frameObject = try frame.map { try JSONSerialization.jsonObject(with: $0) } ?? [:]
            output.append([
                "accepted": accepted, "complete": ledger.hasCompleteWorkEvidence,
                "failure": ledger.failureReason ?? "", "outstanding": ledger.state.outstandingActivityCount,
                "revision": ledger.state.eventRevision.uuidString, "frame": frameObject,
                "lookup": ledger.state.inputID(matchingProviderInputID: "provider-turn-A")?.uuidString.lowercased() ?? "",
                "nextCallback": ledger.nextCallback?.callID ?? "",
                "unissuedReplyProbe": unissuedReplyProbe,
            ])
        }
        try writer.close()
        try outgoing.fileHandleForReading.close()
        if !incomingEnded { try incoming.fileHandleForWriting.close() }
        try incoming.fileHandleForReading.close()
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }

    @MainActor private static func deliver(_ bytes: Data, from pipe: Pipe, to ledger: CodexManagedTurnLedger) throws {
        guard bytes.count <= 1_048_577 else { throw CocoaError(.coderInvalidValue) }
        var offset = 0
        while offset < bytes.count {
            let count = min(1024, bytes.count - offset)
            try pipe.fileHandleForWriting.write(contentsOf: bytes.subdata(in: offset..<(offset + count)))
            var received = Data()
            while received.count < count {
                guard let part = try pipe.fileHandleForReading.read(upToCount: count - received.count),
                      !part.isEmpty else { throw CocoaError(.fileReadUnknown) }
                received.append(part)
            }
            ledger.receive(received)
            offset += count
        }
    }

    @MainActor private static func write(
        _ bytes: Data, action: [String: Any], writer: ShepherdManagedPipeWriter, reader: FileHandle
    ) async throws -> Bool {
        guard bytes.count <= 4096 else { return false }
        let result = await writer.write(bytes, deadline: .now.advanced(by: .seconds(1))) {
            action["refuseWrite"] as? Bool != true
        }
        guard case .complete = result else { return false }
        var actual = Data()
        while actual.count < bytes.count {
            guard let part = try reader.read(upToCount: bytes.count - actual.count), !part.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            actual.append(part)
        }
        guard actual == bytes else { throw CocoaError(.fileReadCorruptFile) }
        return true
    }
}
