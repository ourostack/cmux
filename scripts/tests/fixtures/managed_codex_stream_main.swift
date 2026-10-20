import Foundation

@main
struct ManagedCodexStreamFixture {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let actions = try JSONSerialization.jsonObject(with: input) as? [[String: Any]] else {
            throw CocoaError(.coderInvalidValue)
        }
        var decoder = CodexManagedStreamDecoder()
        let pipe = Pipe()
        var ended = false
        var output: [[String: Any]] = []
        for action in actions {
            var messages: [CodexManagedStreamDecoder.Message] = []
            var failure = ""
            do {
                if let encoded = action["bytes"] as? String, let bytes = Data(base64Encoded: encoded) {
                    if ended || bytes.isEmpty {
                        messages = try decoder.append(bytes)
                    } else {
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
                            messages += try decoder.append(received)
                            offset += count
                        }
                    }
                } else if action["finish"] as? Bool == true {
                    if !ended {
                        try pipe.fileHandleForWriting.close()
                        guard try pipe.fileHandleForReading.read(upToCount: 1) == nil else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        ended = true
                    }
                    try decoder.finish()
                } else {
                    throw CocoaError(.coderInvalidValue)
                }
            } catch let error as CodexManagedStreamDecoder.Failure {
                failure = String(describing: error)
            }
            output.append([
                "messages": messages.map { message -> [String: Any] in
                    let idKind: String
                    switch message.id {
                    case .string: idKind = "string"
                    case .integer: idKind = "integer"
                    case nil: idKind = ""
                    }
                    return ["kind": message.kind.rawValue, "idKind": idKind, "object": message.object]
                },
                "failure": failure, "pending": decoder.hasPendingBytes,
            ])
        }
        if !ended { try pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForReading.close()
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }
}
