import CmuxControlSocket
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
        let hashed = try identity.hash(fileDescriptor: descriptor)
        guard try ShepherdHookExecutableIdentity.capture(path: canonicalPath) == identity else {
            throw CLIError(message: "Shepherd launch executable identity changed during verification.")
        }
        let digest = hashed.sha256
        guard qualifiedBinaries.values.contains(where: { $0.contains(digest) }) else { return nil }
        guard hashed.isNativeExecutable else {
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
