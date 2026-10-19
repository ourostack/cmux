public import Foundation

public enum ShepherdManagedRPCFramingError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidLength
    case headerTooLarge
    case bodyTooLarge
    case invalidUTF8
    case unsupportedEncoding
    case incompleteFrame
    case closed
}

/// Strict UTF-8 Content-Length framing for the pinned private managed RPC transport.
public struct ShepherdManagedRPCFramer: Sendable {
    private static let maximumHeaderBytes = 8_192
    private static let maximumBodyBytes = 1_048_576
    private static let separator = Data([13, 10, 13, 10])
    private var header = Data()
    private var body = Data()
    private var expectedBodyBytes: Int?
    private var terminalFailure: ShepherdManagedRPCFramingError?
    private var isClosed = false

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        if let terminalFailure { throw terminalFailure }
        guard !isClosed && bytes.isEmpty else { throw ShepherdManagedRPCFramingError.closed }
        var frames: [Data] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if let expectedBodyBytes {
                let count = min(expectedBodyBytes - body.count, bytes.distance(from: index, to: bytes.endIndex))
                let end = bytes.index(index, offsetBy: count)
                body.append(bytes[index..<end])
                index = end
                if body.count == expectedBodyBytes {
                    guard String(data: body, encoding: .utf8) != nil else {
                        throw fail(.invalidUTF8)
                    }
                    frames.append(body)
                    body = Data()
                    self.expectedBodyBytes = nil
                }
                continue
            }
            let byte = bytes[index]
            index = bytes.index(after: index)
            guard header.count < Self.maximumHeaderBytes else { throw fail(.headerTooLarge) }
            guard (32...126).contains(byte) || [9, 10, 13].contains(byte),
                  header.last != 13 || byte == 10,
                  byte != 10 || header.last == 13 else {
                throw fail(.invalidHeader)
            }
            header.append(byte)
            if header.suffix(4) == Self.separator {
                let length = try parseHeader()
                header.removeAll(keepingCapacity: true)
                expectedBodyBytes = length
                body.reserveCapacity(length)
            }
        }
        return frames
    }

    /// Called only for actual transport EOF; cancellation and read errors are not EOF.
    public mutating func finish() throws {
        if let terminalFailure { throw terminalFailure }
        guard header.isEmpty, expectedBodyBytes == nil else { throw fail(.incompleteFrame) }
        isClosed = true
    }

    public static func frame(_ body: Data) throws -> Data {
        guard !body.isEmpty else { throw ShepherdManagedRPCFramingError.invalidLength }
        guard body.count <= maximumBodyBytes else { throw ShepherdManagedRPCFramingError.bodyTooLarge }
        guard String(data: body, encoding: .utf8) != nil else { throw ShepherdManagedRPCFramingError.invalidUTF8 }
        var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        result.append(body)
        return result
    }

    private mutating func parseHeader() throws -> Int {
        guard let text = String(data: header, encoding: .ascii) else { throw fail(.invalidHeader) }
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropLast(2) {
            guard let colon = line.firstIndex(of: ":") else { throw fail(.invalidHeader) }
            let key = line[..<colon].lowercased()
            guard key == "content-length" || key == "content-type", fields[key] == nil else {
                throw fail(.invalidHeader)
            }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let value = fields["content-length"] else { throw fail(.invalidHeader) }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(value), length > 0 else { throw fail(.invalidLength) }
        guard length <= Self.maximumBodyBytes else { throw fail(.bodyTooLarge) }
        if let contentType = fields["content-type"] {
            let parts = contentType.lowercased().components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "application/vscode-jsonrpc" || parts.first == "application/json",
                  parts.count == 1 || parts.count == 2
                    && (parts[1] == "charset=utf-8" || parts[1] == "charset=utf8") else {
                throw fail(.unsupportedEncoding)
            }
        }
        return length
    }

    private mutating func fail(_ error: ShepherdManagedRPCFramingError) -> ShepherdManagedRPCFramingError {
        terminalFailure = error
        header = Data()
        body = Data()
        expectedBodyBytes = nil
        return error
    }
}
