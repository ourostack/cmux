import Foundation

@main
struct CopilotManagedConfigurationFixture {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = input["readback"] as? String,
              let readback = CopilotManagedConfiguration.Readback(rawValue: name),
              let result = input["result"] as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let output: [String: Any] = [
            "method": readback.method, "accepted": readback.accepts(result),
        ]
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }
}
