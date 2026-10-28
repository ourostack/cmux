internal import Darwin
public import Foundation

public enum ShepherdManagedBootstrapRead: Equatable, Sendable {
    case waiting
    case receipt(ShepherdManagedBackendLaunchReceipt)
    case providerStderr(Data)
    case endOfFile
    case failed(ShepherdManagedBootstrapError)
}

@MainActor
public final class ShepherdManagedBootstrapReader {
    private let descriptor: Int32
    private let handle: FileHandle
    private var prefix = Data()
    private var receivedReceipt = false
    private var terminal: ShepherdManagedBootstrapRead?
    private var isClosed = false

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
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ShepherdManagedPipeSetupError.systemCall(errno)
        }
        try source.close()
        self.descriptor = descriptor
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        needsClose = false
    }

    public func readNext() -> ShepherdManagedBootstrapRead {
        if let terminal { return terminal }
        // The first phase must leave every byte after the receipt in the pipe.
        let limit = receivedReceipt ? 64 * 1024 : ShepherdManagedBackendLaunchReceipt.byteCount - prefix.count
        var bytes = [UInt8](repeating: 0, count: limit)
        var count: Int
        repeat {
            count = Darwin.read(descriptor, &bytes, limit)
        } while count < 0 && errno == EINTR
        if count < 0 {
            let failure = errno
            if failure == EAGAIN || failure == EWOULDBLOCK { return .waiting }
            return finish(.failed(.readFailed(failure)))
        }
        if count == 0 {
            return finish(receivedReceipt ? .endOfFile : .failed(.truncatedReceipt))
        }
        let data = Data(bytes.prefix(count))
        if receivedReceipt { return .providerStderr(data) }
        prefix.append(data)
        guard prefix.count == ShepherdManagedBackendLaunchReceipt.byteCount else { return .waiting }
        do {
            let receipt = try ShepherdManagedBackendLaunchReceipt(decoding: prefix)
            receivedReceipt = true
            prefix = Data()
            return .receipt(receipt)
        } catch {
            return finish(.failed(.malformedReceipt))
        }
    }

    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        if terminal == nil { terminal = .failed(.closed) }
        try handle.close()
    }

    private func finish(_ result: ShepherdManagedBootstrapRead) -> ShepherdManagedBootstrapRead {
        terminal = result
        return result
    }
}
