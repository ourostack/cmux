import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite struct ShepherdManagedPipeWriterTests {
    @MainActor @Test func admittedBytesActuallyReachTheOwnedPipe() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let frame = Data("owned-frame\n".utf8)
        let result = await writer.write(
            frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
        )
        #expect(result == .complete(frame.count))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == frame)
        #expect(!writer.streamIsTainted)
        try writer.close()
    }

    @MainActor @Test func invalidatedAdmissionWritesZeroBytes() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let result = await writer.write(
            Data("must-not-arrive\n".utf8),
            deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { false }
        )
        #expect(result == .notWritten(.guardInvalidated))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try writer.close()
    }

    @MainActor @Test func aFullPipeSuspendsAndRechecksBeforeAnyInput() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        var allowed = true
        let pending = Task { @MainActor in
            await writer.write(
                Data("new-frame\n".utf8),
                deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { allowed }
            )
        }
        try await waitForManagedBackpressure(writer)
        allowed = false
        #expect(await pending.value == .notWritten(.guardInvalidated))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == filled)
        #expect(!writer.streamIsTainted)
        try writer.close()
    }

    @MainActor @Test func cancellationOfABackpressuredWriteDoesNotAdmitBytes() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let pending = Task { @MainActor in
            await writer.write(
                Data("new-frame\n".utf8),
                deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
            )
        }
        try await waitForManagedBackpressure(writer)
        pending.cancel()
        #expect(await pending.value == .notWritten(.cancelled))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == filled)
        try writer.close()
    }

    @MainActor @Test func aPartialFrameTaintsTheStreamAndCannotBeCompletedByAnotherWrite() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let frame = Data(repeating: 0x58, count: ShepherdManagedPipeWriter.maximumFrameBytes)
        var allowed = true
        let pending = Task { @MainActor in
            await writer.write(
                frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { allowed }
            )
        }
        try await waitForManagedBackpressure(writer)
        allowed = false
        let result = await pending.value
        let received = try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor)
        #expect(!received.isEmpty && received.count < frame.count)
        #expect(result == .partial(received.count, .guardInvalidated))
        #expect(received == frame.prefix(received.count))
        #expect(writer.streamIsTainted)
        #expect(await writer.write(
            Data("must-not-complete\n".utf8),
            deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
        ) == .notWritten(.streamTainted))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try writer.close()
    }

    @MainActor @Test func aCompetingFrameCannotInterleaveWithTheCurrentWriter() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        var allowed = true
        let first = Task { @MainActor in
            await writer.write(
                Data("first\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(1)),
                validate: { allowed }
            )
        }
        try await waitForManagedBackpressure(writer)
        #expect(await writer.write(
            Data("second\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(1)),
            validate: { true }
        ) == .notWritten(.busy))
        allowed = false
        #expect(await first.value == .notWritten(.guardInvalidated))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == filled)
        try writer.close()
    }

    @MainActor @Test func expiryWhileBackpressuredDoesNotExtendTheDeadline() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let result = await writer.write(
            Data("expired\n".utf8),
            deadline: ContinuousClock.now.advanced(by: .milliseconds(20)), validate: { true }
        )
        #expect(result == .notWritten(.deadlineExpired))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == filled)
        try writer.close()
    }

    @MainActor @Test func expiredAndUnboundedLeasesAreRefused() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        #expect(await writer.write(
            Data("past\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(-1)),
            validate: { true }
        ) == .notWritten(.deadlineExpired))
        #expect(await writer.write(
            Data("future\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(3)),
            validate: { true }
        ) == .notWritten(.invalidDeadline))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try writer.close()
    }

    @MainActor @Test func frameBoundsAreEnforcedWithoutWriting() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        for frame in [Data(), Data(repeating: 0x58, count: ShepherdManagedPipeWriter.maximumFrameBytes + 1)] {
            #expect(await writer.write(
                frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
            ) == .notWritten(.invalidFrame))
        }
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try writer.close()
    }

    @MainActor @Test func peerClosureProducesAnErrorNotSIGPIPEOrSuccess() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()
        #expect(await writer.write(
            Data("closed-peer\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(1)),
            validate: { true }
        ) == .notWritten(.writeError(EPIPE)))
        try writer.close()
    }

    @MainActor @Test func backpressureCanDrainAndResumeWithoutInterleavingOrLosingBytes() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let frame = Data(repeating: 0x58, count: 64 * 1024)
        let pending = Task { @MainActor in
            await writer.write(
                frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
            )
        }
        try await waitForManagedBackpressure(writer)
        let targetCount = filled.count + frame.count
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var received = Data()
        while received.count < targetCount, ContinuousClock.now < deadline {
            received.append(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor))
            await Task.yield()
        }
        #expect(await pending.value == .complete(frame.count))
        #expect(received == filled + frame)
        #expect(!writer.streamIsTainted)
        try writer.close()
    }

    @MainActor @Test func aSlowValidatorCannotExtendTheLease() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        var checked = false
        let result = await writer.write(Data("expired-during-check\n".utf8), deadline: deadline) {
            checked = true
            waitPastManagedDeadline(deadline)
            return true
        }
        #expect(checked)
        #expect(result == .notWritten(.deadlineExpired))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try writer.close()
    }

    @MainActor @Test func aValidatorClosingTheWriterCannotAdmitInputAfterItsCheck() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let result = await writer.write(
            Data("closed-during-check\n".utf8),
            deadline: ContinuousClock.now.advanced(by: .seconds(1))
        ) {
            do {
                try writer.close()
                return true
            } catch {
                Issue.record(error)
                return false
            }
        }
        #expect(result == .notWritten(.closed))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor).isEmpty)
    }

    @MainActor @Test func closingWhileBackpressuredPreservesZeroByteOutcome() async throws {
        let pipe = Pipe()
        let filled = try fillManagedPipe(pipe.fileHandleForWriting.fileDescriptor)
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let pending = Task { @MainActor in
            await writer.write(
                Data("closed\n".utf8), deadline: ContinuousClock.now.advanced(by: .seconds(1)),
                validate: { true }
            )
        }
        try await waitForManagedBackpressure(writer)
        try writer.close()
        #expect(await pending.value == .notWritten(.closed))
        #expect(try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor) == filled)
    }

    @MainActor @Test func cancellingAfterPartialAdmissionKeepsTheKnownPartialCount() async throws {
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        try nonblockingManagedRead(pipe.fileHandleForReading.fileDescriptor)
        let frame = Data(repeating: 0x58, count: ShepherdManagedPipeWriter.maximumFrameBytes)
        let pending = Task { @MainActor in
            await writer.write(
                frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
            )
        }
        try await waitForManagedBackpressure(writer)
        pending.cancel()
        let result = await pending.value
        let received = try managedReadAvailable(pipe.fileHandleForReading.fileDescriptor)
        #expect(!received.isEmpty && received.count < frame.count)
        #expect(result == .partial(received.count, .cancelled))
        #expect(received == frame.prefix(received.count))
        #expect(writer.streamIsTainted)
        try writer.close()
    }

    @MainActor @Test func aRegularFileCannotBecomeAProviderInputPipe() throws {
        let source = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        #expect(throws: ShepherdManagedPipeSetupError.notPipe) {
            _ = try ShepherdManagedPipeWriter(takingOwnershipOf: source)
        }
        try source.close()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func transferredPipeOwnershipWorksWithAnActualDisposableChild() async throws {
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let exit = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exit.continuation.yield(process.terminationStatus)
            exit.continuation.finish()
        }
        defer {
            if process.isRunning { process.terminate() }
            exit.continuation.finish()
        }
        try process.run()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: input.fileHandleForWriting)
        let frame = Data("disposable-child-echo\n".utf8)
        #expect(await writer.write(
            frame, deadline: ContinuousClock.now.advanced(by: .seconds(1)), validate: { true }
        ) == .complete(frame.count))
        try writer.close()
        var events = exit.stream.makeAsyncIterator()
        let observedStatus = await events.next()
        let status = try #require(observedStatus)
        #expect(status == 0)
        #expect(try output.fileHandleForReading.readToEnd() == frame)
    }
}

private func waitPastManagedDeadline(_ deadline: ContinuousClock.Instant) {
    while ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
}

private func nonblockingManagedRead(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL, 0)
    try #require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
}

private func fillManagedPipe(_ descriptor: Int32) throws -> Data {
    try nonblockingManagedRead(descriptor)
    let bytes = [UInt8](repeating: 0x46, count: 4096)
    var filled = Data()
    while true {
        let written = bytes.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
        if written < 0, errno == EINTR { continue }
        if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
        try #require(written > 0 && filled.count + written <= 1024 * 1024)
        filled.append(contentsOf: bytes.prefix(written))
    }
    try #require(!filled.isEmpty)
    return filled
}

private func managedReadAvailable(_ descriptor: Int32) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 4096)
    var result = Data()
    while true {
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            result.append(contentsOf: bytes.prefix(count))
            try #require(result.count <= 1024 * 1024)
            continue
        }
        if count == 0 { return result }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return result }
        Issue.record("Unexpected pipe read error: \(errno)")
        throw ManagedPipeTestError.readFailed
    }
}

@MainActor
private func waitForManagedBackpressure(_ writer: ShepherdManagedPipeWriter) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !writer.isAwaitingWritable, ContinuousClock.now < deadline {
        await Task.yield()
    }
    try #require(writer.isAwaitingWritable, "No actual EAGAIN suspension was observed")
}

private enum ManagedPipeTestError: Error {
    case readFailed
}
