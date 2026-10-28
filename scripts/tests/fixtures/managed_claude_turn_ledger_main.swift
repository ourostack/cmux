import CmuxControlSocket
import Foundation

@main
struct ManagedClaudeTurnLedgerFixture {
    @MainActor static func main() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let actions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let identity = ShepherdManagedSessionIdentity(
                hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
                backendPID: 123, backendStartSeconds: 1, backendStartMicroseconds: 0,
                provider: .claude, providerSessionID: "controlled-session", surfaceGeneration: 1,
                executableSHA256: String(repeating: "a", count: 64),
                profileSHA256: String(repeating: "b", count: 64)
              ) else { throw CocoaError(.coderInvalidValue) }
        let ledger = ClaudeManagedTurnLedger(identity: identity, workingDirectory: "/controlled-project")
        let outgoing = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: outgoing.fileHandleForWriting)
        let incoming = Pipe()
        var output: [[String: Any]] = []
        for action in actions {
            let accepted: Bool
            switch action["op"] as? String {
            case "begin":
                guard let text = action["inputID"] as? String, let id = UUID(uuidString: text),
                      let prompt = action["prompt"] as? String else { throw CocoaError(.coderInvalidValue) }
                accepted = ledger.beginInput(id, prompt: prompt)
            case "written":
                guard let text = action["inputID"] as? String, let id = UUID(uuidString: text) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let frame = try JSONSerialization.data(withJSONObject: [
                    "type": "user", "uuid": text, "session_id": "controlled-session",
                    "message": ["role": "user", "content": "Owner input: 雪 🐈"],
                ]) + Data([0x0A])
                let result = await writer.write(frame, deadline: .now.advanced(by: .seconds(1))) {
                    action["refuseWrite"] as? Bool != true
                }
                if case .complete = result {
                    try readExactly(frame, from: outgoing.fileHandleForReading)
                    accepted = ledger.inputWritten(id)
                } else {
                    accepted = false
                }
            case "callbackWritten":
                guard let id = action["requestID"] as? String else { throw CocoaError(.coderInvalidValue) }
                let frame = try JSONSerialization.data(withJSONObject: [
                    "type": "control_response",
                    "response": ["subtype": "success", "request_id": id, "response": [:]] as [String: Any],
                ]) + Data([0x0A])
                let result = await writer.write(frame, deadline: .now.advanced(by: .seconds(1))) {
                    action["refuseWrite"] as? Bool != true
                }
                if case .complete = result {
                    try readExactly(frame, from: outgoing.fileHandleForReading)
                    accepted = ledger.callbackResponseWritten(id)
                } else {
                    accepted = false
                }
            case "beginWork", "finishWork":
                guard let id = action["workID"] as? String else { throw CocoaError(.coderInvalidValue) }
                accepted = action["op"] as? String == "beginWork"
                    ? ledger.beginHostWork(id) : ledger.finishHostWork(id)
            case "event":
                guard let event = action["event"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
                var bytes = try JSONSerialization.data(withJSONObject: event)
                bytes.append(0x0A)
                guard bytes.count <= 4096 else { throw CocoaError(.coderInvalidValue) }
                try incoming.fileHandleForWriting.write(contentsOf: bytes)
                var received = Data()
                while received.count < bytes.count {
                    guard let part = try incoming.fileHandleForReading.read(upToCount: bytes.count - received.count),
                          !part.isEmpty else { throw CocoaError(.fileReadUnknown) }
                    received.append(part)
                }
                ledger.receive(received)
                accepted = ledger.failureReason == nil
            case "raw":
                guard let encoded = action["bytes"] as? String, let bytes = Data(base64Encoded: encoded),
                      bytes.count <= 4096 else { throw CocoaError(.coderInvalidValue) }
                if !bytes.isEmpty {
                    try incoming.fileHandleForWriting.write(contentsOf: bytes)
                    var received = Data()
                    while received.count < bytes.count {
                        guard let part = try incoming.fileHandleForReading.read(upToCount: bytes.count - received.count),
                              !part.isEmpty else { throw CocoaError(.fileReadUnknown) }
                        received.append(part)
                    }
                    ledger.receive(received)
                } else {
                    ledger.receive(bytes)
                }
                accepted = ledger.failureReason == nil
            default:
                throw CocoaError(.coderInvalidValue)
            }
            output.append([
                "accepted": accepted, "complete": ledger.hasCompleteWorkEvidence,
                "failure": ledger.failureReason ?? "", "outstanding": ledger.state.outstandingActivityCount,
                "providerInputID": action["lookupPromptID"].flatMap { $0 as? String }
                    .flatMap { ledger.state.inputID(matchingProviderInputID: $0)?.uuidString.lowercased() } ?? "",
            ])
        }
        try writer.close()
        try outgoing.fileHandleForReading.close()
        try incoming.fileHandleForWriting.close()
        try incoming.fileHandleForReading.close()
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }

    private static func readExactly(_ expected: Data, from handle: FileHandle) throws {
        var actual = Data()
        while actual.count < expected.count {
            guard let part = try handle.read(upToCount: expected.count - actual.count), !part.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            actual.append(part)
        }
        guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
    }
}
