public import Foundation

public enum ShepherdManagedProvider: String, Equatable, Sendable {
    case claude
    case codex
    case copilot
}

/// Owned SDK backend identity. This deliberately has no terminal or TTY field.
public struct ShepherdManagedSessionIdentity: Equatable, Sendable {
    public let hostInstance: UUID
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let backendPID: Int32
    public let backendStartSeconds: Int64
    public let backendStartMicroseconds: Int32
    public let provider: ShepherdManagedProvider
    public let providerSessionID: String
    public let surfaceGeneration: UInt64
    public let executableSHA256: String
    public let profileSHA256: String

    public init?(
        hostInstance: UUID, workspaceID: UUID, surfaceID: UUID,
        backendPID: Int32, backendStartSeconds: Int64, backendStartMicroseconds: Int32,
        provider: ShepherdManagedProvider, providerSessionID: String,
        surfaceGeneration: UInt64, executableSHA256: String, profileSHA256: String
    ) {
        guard backendPID > 0, backendStartSeconds > 0,
              (0..<1_000_000).contains(backendStartMicroseconds),
              surfaceGeneration > 0,
              Self.validIdentifier(providerSessionID),
              Self.validDigest(executableSHA256), Self.validDigest(profileSHA256) else {
            return nil
        }
        self.hostInstance = hostInstance
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.backendPID = backendPID
        self.backendStartSeconds = backendStartSeconds
        self.backendStartMicroseconds = backendStartMicroseconds
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.surfaceGeneration = surfaceGeneration
        self.executableSHA256 = executableSHA256
        self.profileSHA256 = profileSHA256
    }

    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
