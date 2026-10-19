import CmuxControlSocket
import CryptoKit
import Darwin
import Foundation

struct ShepherdHookExecutableVerifier {
    struct Verified {
        let canonicalPath: String
        let digest: String
        let version: String
        let identity: ShepherdHookExecutableIdentity
    }

    static func verify(
        path: String,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) throws -> Verified? {
        guard !qualifiedBinaries.isEmpty else { return nil }
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw CLIError(message: "Shepherd launch executable could not be resolved to an absolute file.")
        }
        defer { free(resolved) }
        let canonicalPath = String(cString: resolved)
        let descriptor = open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw CLIError(message: "Shepherd launch executable could not be opened safely.")
        }
        defer { close(descriptor) }
        let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
        var hash = SHA256()
        var header: [UInt8] = []
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else {
                throw CLIError(message: "Shepherd launch executable could not be hashed completely.")
            }
            if readCount == 0 { break }
            count += Int64(readCount)
            guard count <= identity.byteCount else {
                throw CLIError(message: "Shepherd launch executable changed while it was being hashed.")
            }
            header.append(contentsOf: buffer.prefix(min(readCount, 4 - header.count)))
            hash.update(data: Data(buffer.prefix(readCount)))
        }
        guard count == identity.byteCount,
              try ShepherdHookExecutableIdentity(fileDescriptor: descriptor) == identity,
              try ShepherdHookExecutableIdentity.capture(path: canonicalPath) == identity else {
            throw CLIError(message: "Shepherd launch executable identity changed during verification.")
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard qualifiedBinaries.values.contains(where: { $0.contains(digest) }) else { return nil }
        let nativeHeaders: [[UInt8]] = [
            [0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        guard nativeHeaders.contains(header) else {
            throw CLIError(message: "Shepherd launch qualification requires a direct native agent executable.")
        }
        let output = try versionOutput(path: canonicalPath)
        let suffix = " (Claude Code)"
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), text.hasSuffix(suffix) else {
            throw CLIError(message: "Shepherd launch executable returned an unsupported version response.")
        }
        let version = String(text.dropLast(suffix.count))
        guard ShepherdHookLaunchReceipt.supportsFailureBlocking(version: version),
              qualifiedBinaries[version]?.contains(digest) == true,
              try ShepherdHookExecutableIdentity.capture(path: canonicalPath) == identity,
              try ShepherdHookExecutableIdentity(fileDescriptor: descriptor) == identity else {
            throw CLIError(message: "Shepherd launch version or executable no longer matches the qualified build.")
        }
        return Verified(canonicalPath: canonicalPath, digest: digest, version: version, identity: identity)
    }

    private static func versionOutput(path: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CLIError(message: "Shepherd version probe could not establish bounded output capture.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        try process.run()
        try? output.fileHandleForWriting.close()
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard bytes.count + count <= 4096 else {
                    throw CLIError(message: "Shepherd version probe exceeded its output limit.")
                }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0, !process.isRunning {
                guard process.terminationStatus == 0 else {
                    throw CLIError(message: "Shepherd version probe failed.")
                }
                return bytes
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                throw CLIError(message: "Shepherd version probe output could not be read.")
            }
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&pending, 1, 20) < 0, errno != EINTR {
                throw CLIError(message: "Shepherd version probe output wait failed.")
            }
        }
        throw CLIError(message: "Shepherd version probe exceeded its launch-time deadline.")
    }
}
