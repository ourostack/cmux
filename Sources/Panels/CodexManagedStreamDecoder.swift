import CoreFoundation
import Foundation

/// Pinned raw app-server transport only; envelopes do not establish ownership or work completion.
struct CodexManagedStreamDecoder {
    enum Failure: Error {
        case invalidUTF8, invalidJSON, invalidEnvelope, duplicateKey, lineTooLarge, incompleteLine, closed
    }

    enum RequestID: Hashable {
        case string(String)
        case integer(Int64)

        init?(jsonValue: Any?) {
            if let value = jsonValue as? String, !value.isEmpty, value.utf8.count <= 4096 {
                self = .string(value)
            } else if let value = CodexManagedStreamDecoder.signedInteger(jsonValue) {
                self = .integer(value)
            } else {
                return nil
            }
        }

        var jsonValue: Any {
            switch self {
            case .string(let value): value
            case .integer(let value): value
            }
        }
    }

    struct Message {
        enum Kind: String { case request, notification, response, error }
        let kind: Kind
        let id: RequestID?
        let object: [String: Any]
        let wireByteCount: Int
    }

    private static let maximumLineBytes = 1_048_576
    private var pending = Data()
    private var terminalFailure: Failure?
    private var closed = false

    var hasPendingBytes: Bool { !pending.isEmpty }

    mutating func append(_ bytes: Data) throws -> [Message] {
        if let terminalFailure { throw terminalFailure }
        guard !closed else { throw fail(.closed) }
        var messages: [Message] = []
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

    /// Only actual pipe EOF, not a timeout, read error, cancellation, or dismissal.
    mutating func finish() throws {
        if let terminalFailure { throw terminalFailure }
        guard pending.isEmpty else { throw fail(.incompleteLine) }
        closed = true
    }

    private func decode(_ line: Data) throws -> Message {
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
        guard let object = decoded as? [String: Any] else { throw Failure.invalidEnvelope }
        let id = RequestID(jsonValue: object["id"])
        let keys = Set(object.keys)
        let kind: Message.Kind
        if object["method"] != nil {
            guard let method = object["method"] as? String, !method.isEmpty else {
                throw Failure.invalidEnvelope
            }
            if object["id"] != nil {
                guard id != nil, keys.isSubset(of: ["id", "method", "params", "trace"]),
                      object["trace"] == nil || object["trace"] is NSNull
                        || object["trace"] is [String: Any] else { throw Failure.invalidEnvelope }
                kind = .request
            } else {
                guard keys.isSubset(of: ["method", "params"]) else { throw Failure.invalidEnvelope }
                kind = .notification
            }
        } else {
            guard id != nil else { throw Failure.invalidEnvelope }
            if keys == ["id", "result"] {
                kind = .response
            } else {
                guard keys == ["id", "error"], let error = object["error"] as? [String: Any],
                      Set(error.keys).isSubset(of: ["code", "message", "data"]),
                      Self.signedInteger(error["code"]) != nil, error["message"] is String else {
                    throw Failure.invalidEnvelope
                }
                kind = .error
            }
        }
        return Message(kind: kind, id: id, object: object, wireByteCount: line.count + 1)
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
                .contains(String(cString: number.objCType)) else { return nil }
        return Int64(number.stringValue)
    }

    private mutating func fail(_ error: Failure) -> Failure {
        terminalFailure = error
        pending = Data()
        return error
    }
}
