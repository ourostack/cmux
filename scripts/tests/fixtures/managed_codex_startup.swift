import CmuxControlSocket
import CryptoKit
import Foundation

@main
struct ManagedCodexStartupFixture {
    @MainActor static func main() async throws {
        let requestBytes = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any],
              let nonceString = request["nonce"] as? String, let nonce = UUID(uuidString: nonceString),
              let cwd = request["cwd"] as? String, let descriptor = request["descriptor"],
              let ready = request["ready"] else { throw CocoaError(.coderInvalidValue) }
        var startup = CodexManagedStartup(bootNonce: nonce, workingDirectory: cwd)
        let incoming = Pipe(), outgoing = Pipe()
        let incomingWriter = try ShepherdManagedPipeWriter(takingOwnershipOf: incoming.fileHandleForWriting)
        let outgoingWriter = try ShepherdManagedPipeWriter(takingOwnershipOf: outgoing.fileHandleForWriting)
        var bytes = try JSONSerialization.data(withJSONObject: descriptor) + Data([0x0A])
        if let wire = request["wire"] as? String { bytes = Data(wire.utf8) }
        if request["invalidUTF8"] as? Bool == true { bytes = Data([0xFF, 0x0A]) }
        let fragment = (request["fragmentBytes"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 64
        let deliveredDescriptor = try await deliver(
            bytes, fragment: fragment, writer: incomingWriter,
            reader: incoming.fileHandleForReading, startup: &startup)
        if request["eof"] as? Bool == true { startup.finishStream() }
        let initialize = startup.initializeFrame()
        var initializedObject: [String: Any] = [:]
        var beforeWrite = startup.configurationObserved
        var admitted = false
        if let initialize {
            let written = await outgoingWriter.write(initialize, deadline: .now.advanced(by: .seconds(2))) {
                request["refuseWrite"] as? Bool != true
            }
            if written == .complete(initialize.count) {
                let wire = try readExact(initialize.count, from: outgoing.fileHandleForReading)
                guard let object = try JSONSerialization.jsonObject(with: wire) as? [String: Any],
                      let id = object["id"] else { throw CocoaError(.coderInvalidValue) }
                initializedObject = object
                let response: [String: Any] = [
                    "id": request["foreignReadyID"] as? Bool == true ? "foreign" : id,
                    "result": ready,
                ]
                let reply = try JSONSerialization.data(withJSONObject: response) + Data([0x0A])
                if request["readyBeforeWritten"] as? Bool == true {
                    try await deliver(reply, fragment: fragment, writer: incomingWriter,
                                      reader: incoming.fileHandleForReading, startup: &startup)
                    beforeWrite = startup.configurationObserved
                    admitted = startup.initializeWritten()
                } else {
                    admitted = startup.initializeWritten()
                    beforeWrite = startup.configurationObserved
                    try await deliver(reply, fragment: fragment, writer: incomingWriter,
                                      reader: incoming.fileHandleForReading, startup: &startup)
                }
            }
        }
        let result: [String: Any] = [
            "failure": startup.failureReason ?? "", "threadID": startup.threadID ?? "",
            "ready": startup.configurationObserved, "readyBeforeWrite": beforeWrite,
            "initializeWritten": admitted, "initializeFrame": initializedObject,
            "descriptorWireSHA256": SHA256.hash(data: deliveredDescriptor)
                .map { String(format: "%02x", $0) }.joined(),
            "descriptorNumericTypes": numericTypes(deliveredDescriptor),
        ]
        try incomingWriter.close()
        try outgoingWriter.close()
        try incoming.fileHandleForReading.close()
        try outgoing.fileHandleForReading.close()
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
    }

    @discardableResult
    @MainActor private static func deliver(
        _ bytes: Data, fragment: Int, writer: ShepherdManagedPipeWriter, reader: FileHandle,
        startup: inout CodexManagedStartup
    ) async throws -> Data {
        var offset = 0
        var delivered = Data()
        while offset < bytes.count {
            let count = min(fragment, bytes.count - offset)
            let block = bytes.subdata(in: offset..<(offset + count))
            guard await writer.write(block, deadline: .now.advanced(by: .seconds(2)), validate: { true })
                    == .complete(block.count) else { throw CocoaError(.fileWriteUnknown) }
            let received = try readExact(count, from: reader)
            delivered.append(received)
            startup.receive(received)
            offset += count
        }
        return delivered
    }

    private static func numericTypes(_ bytes: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let profile = params["profile"] as? [String: Any],
              let startup = profile["startupOptions"] as? [String: Any],
              let effective = params["effective"] as? [String: Any] else { return [:] }
        let values = [
            "privateBridgeVersion": profile["privateBridgeVersion"],
            "channelCapacity": startup["channelCapacity"],
            "legacyNotifyCount": effective["legacyNotifyCount"],
        ]
        return values.mapValues { value in
            guard let number = value as? NSNumber else { return "not-a-number" }
            return String(cString: number.objCType)
        }
    }

    private static func readExact(_ count: Int, from reader: FileHandle) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            guard let part = try reader.read(upToCount: count - bytes.count), !part.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            bytes.append(part)
        }
        return bytes
    }
}
