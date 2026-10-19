public import CmuxFoundation
internal import Darwin
public import Foundation

public enum ShepherdManagedBootstrapError: Error, Equatable, Sendable {
    case malformedReceipt
    case truncatedReceipt
    case readFailed(Int32)
    case closed
    case nonceMismatch
    case ownerMismatch
    case supervisorMismatch
    case backendMismatch
    case executableMismatch
    case launchScopeMismatch
}

public struct ShepherdManagedBackendBinding: Sendable {
    public let receipt: ShepherdManagedBackendLaunchReceipt
    fileprivate let executablePath: String
    fileprivate let executableIdentity: ShepherdHookExecutableIdentity
    fileprivate let workingDirectory: String

    public func revalidate() throws {
        try validateAncestry()
        guard let path = ShepherdHookExecutableIdentity.kernelExecutablePath(pid: receipt.backend.pid),
              Self.canonicalPath(path) == executablePath else {
            throw ShepherdManagedBootstrapError.executableMismatch
        }
        do {
            guard try ShepherdHookExecutableIdentity.capture(path: executablePath) == executableIdentity else {
                throw ShepherdManagedBootstrapError.executableMismatch
            }
        } catch {
            throw ShepherdManagedBootstrapError.executableMismatch
        }
        guard let directory = Self.kernelWorkingDirectory(pid: receipt.backend.pid),
              Self.canonicalPath(directory) == workingDirectory else {
            throw ShepherdManagedBootstrapError.launchScopeMismatch
        }
        // Process metadata is useful only while all three original births still exist.
        try validateAncestry()
    }

    private func validateAncestry() throws {
        guard receipt.owner.pid == getpid(),
              AgentPIDProcessIdentity.processSnapshot(pid: receipt.owner.pid)?.identity == receipt.owner else {
            throw ShepherdManagedBootstrapError.ownerMismatch
        }
        guard let supervisor = AgentPIDProcessIdentity.processSnapshot(pid: receipt.supervisor.pid),
              supervisor.identity == receipt.supervisor,
              supervisor.parentPID == receipt.owner.pid else {
            throw ShepherdManagedBootstrapError.supervisorMismatch
        }
        guard let backend = AgentPIDProcessIdentity.processSnapshot(pid: receipt.backend.pid),
              backend.identity == receipt.backend,
              backend.parentPID == receipt.supervisor.pid else {
            throw ShepherdManagedBootstrapError.backendMismatch
        }
    }

    fileprivate static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func kernelWorkingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
    }
}

extension ShepherdManagedBackendLaunchReceipt {
    public func bind(
        expectedNonce: UUID, expectedSupervisor: AgentPIDProcessIdentity,
        executableURL: URL, executableIdentity: ShepherdHookExecutableIdentity,
        workingDirectory: String
    ) throws -> ShepherdManagedBackendBinding {
        guard nonce == expectedNonce else { throw ShepherdManagedBootstrapError.nonceMismatch }
        guard supervisor == expectedSupervisor else { throw ShepherdManagedBootstrapError.supervisorMismatch }
        guard executableURL.isFileURL,
              let executablePath = ShepherdManagedBackendBinding.canonicalPath(executableURL.path) else {
            throw ShepherdManagedBootstrapError.executableMismatch
        }
        guard let directory = ShepherdManagedBackendBinding.canonicalPath(workingDirectory) else {
            throw ShepherdManagedBootstrapError.launchScopeMismatch
        }
        let binding = ShepherdManagedBackendBinding(
            receipt: self, executablePath: executablePath,
            executableIdentity: executableIdentity, workingDirectory: directory
        )
        try binding.revalidate()
        return binding
    }
}

/// Transport ownership evidence only; never provider readiness or input admission.
public struct ShepherdManagedBackendLaunchReceipt: Equatable, Sendable {
    public static let byteCount = 72
    private static let magic: [UInt8] = Array("CMXMSB01".utf8)

    public let nonce: UUID
    public let owner: AgentPIDProcessIdentity
    public let supervisor: AgentPIDProcessIdentity
    public let backend: AgentPIDProcessIdentity

    public init(
        nonce: UUID, owner: AgentPIDProcessIdentity,
        supervisor: AgentPIDProcessIdentity, backend: AgentPIDProcessIdentity
    ) throws {
        guard [owner, supervisor, backend].allSatisfy({
            $0.pid > 0 && $0.startSeconds > 0 && (0..<1_000_000).contains($0.startMicroseconds)
        }) else {
            throw ShepherdManagedBootstrapError.malformedReceipt
        }
        self.nonce = nonce
        self.owner = owner
        self.supervisor = supervisor
        self.backend = backend
    }

    public init(decoding bytes: Data) throws {
        let bytes = [UInt8](bytes)
        guard bytes.count == Self.byteCount, bytes.prefix(8).elementsEqual(Self.magic) else {
            throw ShepherdManagedBootstrapError.malformedReceipt
        }
        let nonce = UUID(uuid: (
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23]
        ))
        func integer(at offset: Int, count: Int) -> UInt64 {
            bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func identity(at offset: Int) throws -> AgentPIDProcessIdentity {
            guard let pid = Int32(exactly: integer(at: offset, count: 4)),
                  let seconds = Int64(exactly: integer(at: offset + 4, count: 8)),
                  let microseconds = Int32(exactly: integer(at: offset + 12, count: 4)) else {
                throw ShepherdManagedBootstrapError.malformedReceipt
            }
            return AgentPIDProcessIdentity(
                pid: pid, startSeconds: seconds, startMicroseconds: Int64(microseconds)
            )
        }
        try self.init(
            nonce: nonce, owner: identity(at: 24),
            supervisor: identity(at: 40), backend: identity(at: 56)
        )
    }

    public func encoded() -> Data {
        var result = Data(Self.magic)
        var uuid = nonce.uuid
        withUnsafeBytes(of: &uuid) { result.append(contentsOf: $0) }
        func append(_ value: UInt64, count: Int) {
            for index in (0..<count).reversed() {
                result.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
            }
        }
        for identity in [owner, supervisor, backend] {
            append(UInt64(identity.pid), count: 4)
            append(UInt64(identity.startSeconds), count: 8)
            append(UInt64(identity.startMicroseconds), count: 4)
        }
        return result
    }
}
