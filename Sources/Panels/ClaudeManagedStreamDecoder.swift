import Foundation

/// Raw managed transport only. Decoding a message does not establish attribution or completion.
struct ClaudeManagedStreamDecoder {
    enum Failure: Error {
        case invalidUTF8, invalidJSON, invalidEnvelope, duplicateKey, lineTooLarge, incompleteLine, closed
    }

    private static let maximumLineBytes = 1_048_576
    private var pending = Data()
    private var terminalFailure: Failure?
    private var closed = false

    var hasPendingBytes: Bool { !pending.isEmpty }

    mutating func append(_ bytes: Data) throws -> [[String: Any]] {
        if let terminalFailure { throw terminalFailure }
        guard !closed else { throw fail(.closed) }
        var messages: [[String: Any]] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let newline = bytes[cursor...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.endIndex
            let count = bytes.distance(from: cursor, to: end)
            guard count <= Self.maximumLineBytes - pending.count else { throw fail(.lineTooLarge) }
            pending.append(bytes[cursor..<end])
            guard let newline else { break }
            do {
                messages.append(try decode(pending))
            } catch let error as Failure {
                throw fail(error)
            }
            pending.removeAll(keepingCapacity: true)
            cursor = bytes.index(after: newline)
        }
        return messages
    }

    /// Only actual pipe EOF, not a read error, cancellation, timer, or UI dismissal.
    mutating func finish() throws {
        if let terminalFailure { throw terminalFailure }
        guard pending.isEmpty else { throw fail(.incompleteLine) }
        closed = true
    }

    private func decode(_ line: Data) throws -> [String: Any] {
        guard String(data: line, encoding: .utf8) != nil else { throw Failure.invalidUTF8 }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: line)
            guard try !AgentSessionManagedJSON.containsDuplicateKeys(line) else { throw Failure.duplicateKey }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.invalidJSON
        }
        guard let object = decoded as? [String: Any],
              let type = object["type"] as? String, !type.isEmpty else {
            throw Failure.invalidEnvelope
        }
        return object
    }

    private mutating func fail(_ error: Failure) -> Failure {
        terminalFailure = error
        pending = Data()
        return error
    }
}
