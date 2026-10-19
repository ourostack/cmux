import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation
import Testing

@Suite struct ShepherdManagedBootstrapReaderTests {
    @MainActor @Test func everySplitRetainsOnlyThePrefixUntilItIsComplete() throws {
        let frame = try readerReceipt().encoded()
        for split in 1..<72 {
            let pipe = Pipe()
            let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
            defer { try? reader.close() }
            #expect(reader.readNext() == .waiting)
            try pipe.fileHandleForWriting.write(contentsOf: frame.prefix(split))
            #expect(reader.readNext() == .waiting)
            #expect(reader.readNext() == .waiting)
            try pipe.fileHandleForWriting.write(contentsOf: frame.dropFirst(split))
            #expect(reader.readNext() == .receipt(try readerReceipt()))
            #expect(reader.readNext() == .waiting)
        }
    }

    @MainActor @Test func coalescedProviderBytesRemainInTheKernelUntilAfterTheReceiptRead() throws {
        let pipe = Pipe()
        let alias = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        #expect(alias >= 0)
        defer { _ = Darwin.close(alias) }
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
        defer { try? reader.close() }
        let tail = Data("provider stderr, never bootstrap metadata\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: readerReceipt().encoded() + tail)
        #expect(reader.readNext() == .receipt(try readerReceipt()))
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(alias, &bytes, bytes.count)
        #expect(count == tail.count)
        #expect(Data(bytes.prefix(max(0, count))) == tail)
        #expect(reader.readNext() == .waiting)
    }

    @MainActor @Test func anIdenticalLaterFrameIsOnlyUntrustedStderr() async throws {
        let pipe = Pipe()
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
        defer { try? reader.close() }
        let receipt = try readerReceipt()
        try pipe.fileHandleForWriting.write(contentsOf: receipt.encoded() + receipt.encoded())
        #expect(reader.readNext() == .receipt(receipt))
        #expect(reader.readNext() == .providerStderr(receipt.encoded()))
        try pipe.fileHandleForWriting.close()
        #expect(try await nextBootstrapResult(reader) == .endOfFile)
        #expect(reader.readNext() == .endOfFile)
    }

    @MainActor @Test func anInvalidFirstFrameCannotRearmOrScanForALaterValidOne() throws {
        let pipe = Pipe()
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
        defer { try? reader.close() }
        let frame = try readerReceipt().encoded()
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0, count: 72) + frame)
        #expect(reader.readNext() == .failed(.malformedReceipt))
        #expect(reader.readNext() == .failed(.malformedReceipt))
    }

    @MainActor @Test func everyTruncatedPrefixFailsRatherThanReportingAnOrdinaryDrain() async throws {
        let frame = try readerReceipt().encoded()
        for length in 0..<72 {
            let pipe = Pipe()
            let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
            defer { try? reader.close() }
            if length > 0 {
                try pipe.fileHandleForWriting.write(contentsOf: frame.prefix(length))
                #expect(reader.readNext() == .waiting)
            }
            try pipe.fileHandleForWriting.close()
            #expect(try await nextBootstrapResult(reader) == .failed(.truncatedReceipt))
            #expect(reader.readNext() == .failed(.truncatedReceipt))
        }
    }

    @MainActor @Test func anActualReadErrorIsStickyAndNeverEOF() throws {
        let pipe = Pipe()
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForWriting)
        defer { try? reader.close() }
        #expect(reader.readNext() == .failed(.readFailed(EBADF)))
        #expect(reader.readNext() == .failed(.readFailed(EBADF)))
    }

    @MainActor @Test func explicitCloseDoesNotFabricateEOF() throws {
        let pipe = Pipe()
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: pipe.fileHandleForReading)
        try reader.close()
        #expect(reader.readNext() == .failed(.closed))
        try reader.close()
    }

    @MainActor @Test func nonPipesAreRefusedBeforeAnyBootstrapRead() throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? handle.close() }
        #expect(throws: ShepherdManagedPipeSetupError.notPipe) {
            try ShepherdManagedBootstrapReader(takingOwnershipOf: handle)
        }
    }
}

@MainActor
private func nextBootstrapResult(_ reader: ShepherdManagedBootstrapReader) async throws -> ShepherdManagedBootstrapRead {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        let result = reader.readNext()
        if result != .waiting { return result }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw POSIXError(.ETIMEDOUT)
}

private func readerReceipt() throws -> ShepherdManagedBackendLaunchReceipt {
    try ShepherdManagedBackendLaunchReceipt(
        nonce: #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
        owner: AgentPIDProcessIdentity(pid: 123, startSeconds: 100, startMicroseconds: 1),
        supervisor: AgentPIDProcessIdentity(pid: 456, startSeconds: 200, startMicroseconds: 2),
        backend: AgentPIDProcessIdentity(pid: 789, startSeconds: 300, startMicroseconds: 3)
    )
}
