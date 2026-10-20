import Foundation

enum AgentSessionManagedJSON {
    private enum Failure: Error { case invalidKey }

    private final class ObjectKeys {
        var names: Set<String> = []
        var expectsKey = true
    }

    private enum Scope {
        case object(ObjectKeys)
        case array
    }

    /// Call after JSON validation; Foundation otherwise overwrites duplicate identity members.
    static func containsDuplicateKeys(_ line: Data) throws -> Bool {
        let bytes = [UInt8](line)
        var scopes: [Scope] = []
        var cursor = 0
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 0x7B:
                scopes.append(.object(ObjectKeys()))
            case 0x5B:
                scopes.append(.array)
            case 0x7D, 0x5D:
                _ = scopes.popLast()
            case 0x2C:
                if case .object(let keys)? = scopes.last { keys.expectsKey = true }
            case 0x22:
                let start = cursor
                cursor += 1
                while cursor < bytes.count, bytes[cursor] != 0x22 {
                    cursor += bytes[cursor] == 0x5C ? 2 : 1
                }
                guard cursor < bytes.count else { throw Failure.invalidKey }
                cursor += 1
                if case .object(let keys)? = scopes.last, keys.expectsKey {
                    let value = try JSONSerialization.jsonObject(
                        with: Data(bytes[start..<cursor]), options: .fragmentsAllowed
                    )
                    guard let key = value as? String else { throw Failure.invalidKey }
                    guard keys.names.insert(key).inserted else { return true }
                    keys.expectsKey = false
                }
                continue
            default:
                break
            }
            cursor += 1
        }
        return false
    }
}
