import CmuxControlSocket
import Foundation

@main
struct ManagedCopilotTurnLedgerFixture {
    @MainActor static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let identity = ShepherdManagedSessionIdentity(
                hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
                backendPID: 123, backendStartSeconds: 1, backendStartMicroseconds: 0,
                provider: .copilot, providerSessionID: "controlled-session", surfaceGeneration: 1,
                executableSHA256: String(repeating: "a", count: 64),
                profileSHA256: String(repeating: "b", count: 64)
              ) else { throw CocoaError(.coderInvalidValue) }
        let ledger = CopilotManagedTurnLedger(identity: identity)
        var token: UUID?
        var responses: [[String: Any]] = []
        for action in input {
            let accepted: Bool
            switch action["op"] as? String {
            case "begin":
                guard let text = action["inputID"] as? String, let id = UUID(uuidString: text) else {
                    throw CocoaError(.coderInvalidValue)
                }
                accepted = ledger.beginInput(id, origin: action["supervisor"] as? Bool == true ? .supervisor : .owner)
            case "ack":
                guard let text = action["inputID"] as? String, let id = UUID(uuidString: text),
                      let providerID = action["providerID"] as? String else {
                    throw CocoaError(.coderInvalidValue)
                }
                accepted = ledger.acknowledgeInput(id, providerInputID: providerID)
            case "event":
                guard let event = action["event"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
                ledger.receive(try JSONSerialization.data(withJSONObject: event))
                accepted = ledger.failureReason == nil
            case "beginWork":
                token = ledger.beginWorkReadback()
                accepted = token != nil
            case "readback":
                guard let name = action["readback"] as? String,
                      let readback = CopilotManagedTurnLedger.WorkReadback(rawValue: name),
                      let result = action["result"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
                accepted = ledger.acceptWorkReadback(
                    readback, token: action["foreignToken"] as? Bool == true ? UUID() : (token ?? UUID()), result: result
                )
            default:
                throw CocoaError(.coderInvalidValue)
            }
            responses.append([
                "accepted": accepted, "complete": ledger.hasCompleteWorkEvidence,
                "failure": ledger.failureReason ?? "", "hold": ledger.state.holdReason.map { "\($0)" } ?? "",
            ])
        }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: responses))
    }
}
