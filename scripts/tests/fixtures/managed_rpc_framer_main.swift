import Foundation

@main
struct ManagedRPCFramerFixture {
    static func main() throws {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chunks = input["chunks"] as? [String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var framer = ShepherdManagedRPCFramer()
        var frames: [Data] = []
        var failure: String?
        do {
            for chunk in chunks {
                guard let bytes = Data(base64Encoded: chunk) else { throw CocoaError(.fileReadCorruptFile) }
                frames += try framer.append(bytes)
            }
            if input["finish"] as? Bool == true { try framer.finish() }
        } catch {
            failure = String(describing: error)
        }
        var result: [String: Any] = [
            "frames": frames.map { $0.base64EncodedString() },
            "error": failure.map { $0 as Any } ?? NSNull(),
        ]
        if let followup = input["followup"] as? String, let bytes = Data(base64Encoded: followup) {
            do {
                _ = try framer.append(bytes)
                result["followupError"] = NSNull()
            } catch { result["followupError"] = String(describing: error) }
        }
        if let encoded = input["encode"] as? String, let bytes = Data(base64Encoded: encoded) {
            do { result["encoded"] = try ShepherdManagedRPCFramer.frame(bytes).base64EncodedString() }
            catch { result["encodeError"] = String(describing: error) }
        }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
    }
}
