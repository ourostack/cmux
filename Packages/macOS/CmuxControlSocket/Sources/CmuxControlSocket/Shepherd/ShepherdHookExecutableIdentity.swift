internal import Foundation
internal import Darwin
internal import CryptoKit

/// Stable metadata for the exact file hashed and probed during a qualified launch.
public struct ShepherdHookExecutableIdentity: Codable, Equatable, Sendable {
    public struct Digest: Sendable {
        public let sha256: String
        public let isNativeExecutable: Bool
    }

    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    public var isValid: Bool {
        device > 0 && inode > 0 && byteCount > 0 && byteCount <= 512 * 1024 * 1024
            && modificationSeconds > 0 && changeSeconds > 0
            && (0..<1_000_000_000).contains(modificationNanoseconds)
            && (0..<1_000_000_000).contains(changeNanoseconds)
    }

    public init(
        device: UInt64, inode: UInt64, byteCount: Int64,
        modificationSeconds: Int64, modificationNanoseconds: Int64,
        changeSeconds: Int64, changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    public init(fileDescriptor: Int32) throws {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try self.init(validating: info)
    }

    public static func capture(path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let before = try Self(fileDescriptor: descriptor)
        var current = stat()
        guard lstat(path, &current) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try Self(validating: current) == before,
              try Self(fileDescriptor: descriptor) == before else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return before
    }

    public static func kernelExecutablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The caller owns the descriptor and separately revalidates its path binding.
    public func hash(fileDescriptor: Int32) throws -> Digest {
        guard try Self(fileDescriptor: fileDescriptor) == self else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var hash = SHA256()
        var header: [UInt8] = []
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if readCount == 0 { break }
            count += Int64(readCount)
            guard count <= byteCount else { throw CocoaError(.fileReadCorruptFile) }
            header.append(contentsOf: buffer.prefix(min(readCount, 4 - header.count)))
            hash.update(data: Data(buffer.prefix(readCount)))
        }
        guard count == byteCount, try Self(fileDescriptor: fileDescriptor) == self else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let nativeHeaders: [[UInt8]] = [
            [0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        return Digest(
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            isNativeExecutable: nativeHeaders.contains(header)
        )
    }

    private init(validating info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0,
              info.st_mode & 0o022 == 0, info.st_uid == 0 || info.st_uid == geteuid(),
              let device = UInt64(exactly: info.st_dev) else {
            throw CocoaError(.fileReadNoPermission)
        }
        self.init(
            device: device, inode: UInt64(info.st_ino), byteCount: info.st_size,
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
        guard isValid else { throw CocoaError(.fileReadCorruptFile) }
    }
}
