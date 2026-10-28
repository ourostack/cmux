import Foundation

@main
struct ManagedCodexShellInventoryFixture {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let actions = try JSONSerialization.jsonObject(with: input) as? [[String: Any]],
              let initialRevision = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") else {
            throw CocoaError(.coderInvalidValue)
        }
        var inventory = CodexManagedShellInventory(threadID: "thread-A", eventRevision: initialRevision)
        var output: [[String: Any]] = []
        for action in actions {
            let revision = (action["revision"] as? String).flatMap(UUID.init(uuidString:)) ?? initialRevision
            let id: CodexManagedStreamDecoder.RequestID?
            if let value = action["id"] as? String {
                id = .string(value)
            } else {
                id = CodexManagedStreamDecoder.RequestID(jsonValue: action["id"])
            }
            var accepted = true
            var request: [String: Any] = [:]
            switch action["op"] as? String {
            case "request":
                guard let id else { throw CocoaError(.coderInvalidValue) }
                if let value = inventory.requestNextPage(id: id, currentRevision: revision) {
                    request = value
                } else {
                    accepted = false
                }
            case "written":
                guard let id else { throw CocoaError(.coderInvalidValue) }
                accepted = inventory.pageWritten(id: id, currentRevision: revision)
            case "response":
                guard let wire = action["wire"] as? String else {
                    throw CocoaError(.coderInvalidValue)
                }
                var decoder = CodexManagedStreamDecoder()
                let messages = try decoder.append(Data(wire.utf8))
                guard messages.count == 1 else { throw CocoaError(.coderInvalidValue) }
                accepted = inventory.receive(messages[0], currentRevision: revision)
            case "snapshot":
                break
            default:
                throw CocoaError(.coderInvalidValue)
            }
            output.append([
                "accepted": accepted, "failure": inventory.failureReason ?? "",
                "complete": inventory.isComplete, "emptyComplete": inventory.hasEmptyCompleteSnapshot,
                "terminals": action["suppressTerminals"] as? Bool == true ? [] : inventory.terminals,
                "terminalCount": inventory.terminals.count, "request": request,
            ])
        }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }
}
