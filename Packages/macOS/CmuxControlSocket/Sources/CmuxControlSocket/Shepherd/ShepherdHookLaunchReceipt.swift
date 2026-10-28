public import Foundation

/// Launch-only binding of a supported hook runtime to the future native root.
public struct ShepherdHookLaunchReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let hostInstance: UUID
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let pid: Int32
    public let pidStartSeconds: Int64
    public let pidStartMicroseconds: Int64
    public let executablePath: String
    public var executableSHA256: String
    public let executableIdentity: ShepherdHookExecutableIdentity?
    public let settingsSHA256: String
    public var agentVersion: String

    public init(
        id: UUID, hostInstance: UUID, workspaceID: UUID, surfaceID: UUID,
        pid: Int32, pidStartSeconds: Int64, pidStartMicroseconds: Int64,
        executablePath: String, executableSHA256: String, settingsSHA256: String,
        agentVersion: String, executableIdentity: ShepherdHookExecutableIdentity? = nil
    ) {
        self.id = id
        self.hostInstance = hostInstance
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.pid = pid
        self.pidStartSeconds = pidStartSeconds
        self.pidStartMicroseconds = pidStartMicroseconds
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
        self.executableIdentity = executableIdentity
        self.settingsSHA256 = settingsSHA256
        self.agentVersion = agentVersion
    }

    public func isQualified(using binaries: [String: Set<String>]) -> Bool {
        guard Self.supportsFailureBlocking(version: agentVersion),
              pid > 0, pidStartSeconds > 0, (0..<1_000_000).contains(pidStartMicroseconds),
              executablePath.hasPrefix("/"), !executablePath.utf8.contains(0),
              executableIdentity?.isValid == true,
              Self.isDigest(executableSHA256), Self.isDigest(settingsSHA256) else { return false }
        return binaries[agentVersion]?.contains(executableSHA256) == true
    }

    public static func supportsFailureBlocking(version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "2", parts[1] == "1",
              parts[2].allSatisfy({ $0.isASCII && $0.isNumber }),
              let patch = Int(parts[2]), patch >= 295, String(patch) == parts[2] else { return false }
        return true
    }

    public static func captureHost(
        inspection: Data, workspaceID: UUID, surfaceID: UUID
    ) throws -> UUID? {
        let value = try JSONDecoder().decode(HostInspection.self, from: inspection)
        guard value.protocol_version == 1, value.snapshot.workspace_id == workspaceID,
              value.snapshot.surface_id == surfaceID, value.snapshot.surface_generation > 0 else {
            return nil
        }
        return value.host_instance
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct HostInspection: Decodable {
        let protocol_version: Int
        let host_instance: UUID
        let snapshot: HostSnapshot
    }

    private struct HostSnapshot: Decodable {
        let workspace_id: UUID
        let surface_id: UUID
        let surface_generation: UInt64
    }
}
