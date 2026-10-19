internal import Darwin
public import Foundation

public enum ShepherdManagedPipeSetupError: Error, Equatable, Sendable {
    case notPipe
    case systemCall(Int32)
}

public enum ShepherdManagedPipeWriteReason: Equatable, Sendable {
    case closed
    case streamTainted
    case busy
    case invalidFrame
    case invalidDeadline
    case deadlineExpired
    case guardInvalidated
    case cancelled
    case writeError(Int32)
    case zeroWrite
    case waitFailed
}

/// Byte admission, not provider consumption or an automatic-input receipt.
public enum ShepherdManagedPipeWriteResult: Equatable, Sendable {
    case complete(Int)
    case notWritten(ShepherdManagedPipeWriteReason)
    case partial(Int, ShepherdManagedPipeWriteReason)
}

@MainActor
public final class ShepherdManagedPipeWriter {
    public static let maximumFrameBytes = 256 * 1024

    private let descriptor: Int32
    private let handle: FileHandle
    private var isClosed = false
    private var isWriting = false
    public private(set) var streamIsTainted = false
    public private(set) var isAwaitingWritable = false

    public init(takingOwnershipOf source: FileHandle) throws {
        let descriptor = fcntl(source.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ShepherdManagedPipeSetupError.systemCall(errno) }
        var needsClose = true
        defer {
            if needsClose { _ = Darwin.close(descriptor) }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ShepherdManagedPipeSetupError.systemCall(errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else {
            throw ShepherdManagedPipeSetupError.notPipe
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ShepherdManagedPipeSetupError.systemCall(errno)
        }
        try source.close()
        self.descriptor = descriptor
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        needsClose = false
    }

    public func write(
        _ frame: Data, deadline: ContinuousClock.Instant,
        validate: @MainActor () -> Bool
    ) async -> ShepherdManagedPipeWriteResult {
        if isClosed { return .notWritten(.closed) }
        if streamIsTainted { return .notWritten(.streamTainted) }
        if isWriting { return .notWritten(.busy) }
        guard !frame.isEmpty, frame.count <= Self.maximumFrameBytes else {
            return .notWritten(.invalidFrame)
        }
        let started = ContinuousClock.now
        guard started < deadline else { return .notWritten(.deadlineExpired) }
        guard started.duration(to: deadline) <= .seconds(2) else {
            return .notWritten(.invalidDeadline)
        }
        isWriting = true
        defer {
            isWriting = false
            isAwaitingWritable = false
        }
        var offset = 0
        while offset < frame.count {
            if let reason = refusal(deadline: deadline, validate: validate) {
                return stopped(reason, admittedBytes: offset)
            }
            // No await between the live guard and this nonblocking admission.
            let (written, failure) = frame.withUnsafeBytes { buffer -> (Int, Int32) in
                guard let base = buffer.baseAddress else { return (0, 0) }
                let result = Darwin.write(
                    descriptor, base.advanced(by: offset), min(4096, buffer.count - offset)
                )
                return (result, result < 0 ? errno : 0)
            }
            if written > 0 {
                offset += written
                if offset < frame.count { await Task.yield() }
                continue
            }
            if written < 0, failure == EINTR { continue }
            if written < 0, failure == EAGAIN || failure == EWOULDBLOCK {
                isAwaitingWritable = true
                do {
                    try await Task.sleep(for: .milliseconds(2))
                } catch is CancellationError {
                    return stopped(.cancelled, admittedBytes: offset)
                } catch {
                    return stopped(.waitFailed, admittedBytes: offset)
                }
                isAwaitingWritable = false
                continue
            }
            return stopped(
                written == 0 ? .zeroWrite : .writeError(failure), admittedBytes: offset
            )
        }
        return .complete(offset)
    }

    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        try handle.close()
    }

    private func refusal(
        deadline: ContinuousClock.Instant, validate: @MainActor () -> Bool
    ) -> ShepherdManagedPipeWriteReason? {
        if isClosed { return .closed }
        if Task.isCancelled { return .cancelled }
        if ContinuousClock.now >= deadline { return .deadlineExpired }
        guard validate() else { return .guardInvalidated }
        if isClosed { return .closed }
        if Task.isCancelled { return .cancelled }
        if ContinuousClock.now >= deadline { return .deadlineExpired }
        return nil
    }

    private func stopped(
        _ reason: ShepherdManagedPipeWriteReason, admittedBytes: Int
    ) -> ShepherdManagedPipeWriteResult {
        guard admittedBytes > 0 else { return .notWritten(reason) }
        streamIsTainted = true
        return .partial(admittedBytes, reason)
    }
}
