import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation
import Testing

@Suite struct ShepherdManagedBackendLaunchReceiptTests {
    @Test func decodesTheExactFixedWidthNetworkOrderReceipt() throws {
        let receipt = try ShepherdManagedBackendLaunchReceipt(decoding: bootstrapFixture)
        #expect(receipt.nonce == UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        #expect(receipt.owner == AgentPIDProcessIdentity(pid: 123, startSeconds: 100, startMicroseconds: 1))
        #expect(receipt.supervisor == AgentPIDProcessIdentity(pid: 456, startSeconds: 200, startMicroseconds: 999_999))
        #expect(receipt.backend == AgentPIDProcessIdentity(pid: 789, startSeconds: 300, startMicroseconds: 0))
    }

    @Test func encodingProducesTheIndependentlySpecifiedWireBytes() throws {
        let receipt = try ShepherdManagedBackendLaunchReceipt(
            nonce: #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
            owner: AgentPIDProcessIdentity(pid: 123, startSeconds: 100, startMicroseconds: 1),
            supervisor: AgentPIDProcessIdentity(pid: 456, startSeconds: 200, startMicroseconds: 999_999),
            backend: AgentPIDProcessIdentity(pid: 789, startSeconds: 300, startMicroseconds: 0)
        )
        #expect(receipt.encoded() == bootstrapFixture)
    }

    @Test func rejectsWrongLengthsMagicAndVersionWithoutScanningForAnotherFrame() {
        for bytes in [
            Data(), Data(bootstrapFixture.dropLast()), bootstrapFixture + Data([0]),
            Data([0]) + bootstrapFixture,
            replacingBootstrapBytes(bootstrapFixture, at: 0, with: [0x58]),
            replacingBootstrapBytes(bootstrapFixture, at: 7, with: [0x32]),
        ] {
            #expect(throws: ShepherdManagedBootstrapError.malformedReceipt) {
                try ShepherdManagedBackendLaunchReceipt(decoding: bytes)
            }
        }
    }

    @Test func everyBirthRecordRejectsUnsignedOverflowAndInvalidMicroseconds() {
        for offset in [24, 40, 56] {
            for (relative, bytes) in [
                (0, [UInt8](repeating: 0, count: 4)),
                (0, [0x80, 0, 0, 0]),
                (4, [UInt8](repeating: 0, count: 8)),
                (4, [0x80, 0, 0, 0, 0, 0, 0, 0]),
                (12, [0, 0x0f, 0x42, 0x40]),
                (12, [0xff, 0xff, 0xff, 0xff]),
            ] {
                let malformed = replacingBootstrapBytes(bootstrapFixture, at: offset + relative, with: bytes)
                #expect(throws: ShepherdManagedBootstrapError.malformedReceipt) {
                    try ShepherdManagedBackendLaunchReceipt(decoding: malformed)
                }
            }
        }
    }

    @Test func cannotEncodeInvalidBirthsByClampingOrTruncating() throws {
        let good = AgentPIDProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: 0)
        for bad in [
            AgentPIDProcessIdentity(pid: 0, startSeconds: 1, startMicroseconds: 0),
            AgentPIDProcessIdentity(pid: -1, startSeconds: 1, startMicroseconds: 0),
            AgentPIDProcessIdentity(pid: 1, startSeconds: 0, startMicroseconds: 0),
            AgentPIDProcessIdentity(pid: 1, startSeconds: -1, startMicroseconds: 0),
            AgentPIDProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: -1),
            AgentPIDProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: 1_000_000),
            AgentPIDProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: Int64.max),
        ] {
            for position in 0..<3 {
                #expect(throws: ShepherdManagedBootstrapError.malformedReceipt) {
                    try ShepherdManagedBackendLaunchReceipt(
                        nonce: UUID(), owner: position == 0 ? bad : good,
                        supervisor: position == 1 ? bad : good, backend: position == 2 ? bad : good
                    )
                }
            }
        }
    }
}

private let bootstrapFixture = Data([
    0x43, 0x4d, 0x58, 0x4d, 0x53, 0x42, 0x30, 0x31,
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    0, 0, 0, 123, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 1,
    0, 0, 1, 200, 0, 0, 0, 0, 0, 0, 0, 200, 0, 0x0f, 0x42, 0x3f,
    0, 0, 3, 21, 0, 0, 0, 0, 0, 0, 1, 44, 0, 0, 0, 0,
])

private func replacingBootstrapBytes(_ input: Data, at offset: Int, with bytes: [UInt8]) -> Data {
    var result = input
    result.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    return result
}
