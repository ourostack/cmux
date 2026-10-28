public import Foundation
internal import Darwin

/// Exact native epoch to which a complete hook registry observation belongs.
public struct ShepherdHookReadinessScope: Codable, Equatable, Sendable {
    public var hostInstance: UUID
    public var workspaceID: UUID
    public var surfaceID: UUID
    public var processInstance: String
    public var pid: Int32
    public var pidStartSeconds: Int64
    public var pidStartMicroseconds: Int64
    public var surfaceGeneration: UInt64
    public var inputRevision: UInt64

    public init(
        hostInstance: UUID, workspaceID: UUID, surfaceID: UUID,
        processInstance: String, pid: Int32, pidStartSeconds: Int64,
        pidStartMicroseconds: Int64, surfaceGeneration: UInt64, inputRevision: UInt64
    ) {
        self.hostInstance = hostInstance
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.processInstance = processInstance
        self.pid = pid
        self.pidStartSeconds = pidStartSeconds
        self.pidStartMicroseconds = pidStartMicroseconds
        self.surfaceGeneration = surfaceGeneration
        self.inputRevision = inputRevision
    }

    fileprivate var isValid: Bool {
        pid > 0 && pidStartSeconds > 0 && (0..<1_000_000).contains(pidStartMicroseconds)
            && surfaceGeneration > 0 && processInstance.hasPrefix("\(pid):")
            && UInt64(processInstance.dropFirst("\(pid):".count)).map { $0 > 0 } == true
    }

    /// Captures only metadata from an exact-target native read; no screen or token is retained.
    public static func capture(
        inspection data: Data, workspaceID: UUID, surfaceID: UUID, pid: Int32,
        pidStartSeconds: Int64, pidStartMicroseconds: Int64
    ) throws -> Self? {
        let inspection = try JSONDecoder().decode(Inspection.self, from: data)
        let snapshot = inspection.snapshot
        guard inspection.protocol_version == 1, snapshot.agent == "claude",
              snapshot.workspace_id == workspaceID, snapshot.surface_id == surfaceID,
              let process = snapshot.process_instance else { return nil }
        let scope = Self(
            hostInstance: inspection.host_instance, workspaceID: workspaceID, surfaceID: surfaceID,
            processInstance: process, pid: pid, pidStartSeconds: pidStartSeconds,
            pidStartMicroseconds: pidStartMicroseconds, surfaceGeneration: snapshot.surface_generation,
            inputRevision: snapshot.input_revision
        )
        return scope.isValid ? scope : nil
    }

    private struct Inspection: Decodable {
        let protocol_version: Int
        let host_instance: UUID
        let snapshot: Snapshot
    }

    private struct Snapshot: Decodable {
        let workspace_id: UUID
        let surface_id: UUID
        let process_instance: String?
        let agent: String?
        let surface_generation: UInt64
        let input_revision: UInt64
    }
}

/// Supported Claude Stop registry coverage, never inferred from a legacy pending flag.
public struct ShepherdHookReadinessProof: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let scope: ShepherdHookReadinessScope
    public let nonce: UUID

    /// Only explicit, complete, empty task AND scheduled-wakeup registries qualify.
    public init?(stopInput: [String: Any], sessionID: String, scope: ShepherdHookReadinessScope) {
        guard scope.isValid, !sessionID.isEmpty,
              let tasks = stopInput["background_tasks"] as? [Any], tasks.isEmpty,
              let crons = stopInput["session_crons"] as? [Any], crons.isEmpty else { return nil }
        version = 1
        self.sessionID = sessionID
        self.scope = scope
        nonce = UUID()
    }

    /// Reads the same configured Claude store as the hook CLI, without salvage or unbounded allocation.
    public static func loadStoreData(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Data? {
        let path: String
        if let override = environment["CMUX_CLAUDE_HOOK_STATE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            path = NSString(string: override).expandingTildeInPath
        } else if let directory = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            path = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
                .appendingPathComponent("claude-hook-sessions.json").path
        } else {
            path = NSString(string: "~/.cmuxterm/claude-hook-sessions.json").expandingTildeInPath
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_mode & 0o022 == 0,
              before.st_size >= 0, before.st_size <= 8 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            guard data.count + count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == before.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    /// Strictly decodes the complete store. Malformed siblings cannot be dropped.
    public static func readStore(
        _ data: Data, matching scope: ShepherdHookReadinessScope
    ) throws -> Self? {
        guard data.count <= 8 * 1024 * 1024, scope.isValid else { return nil }
        let store = try JSONDecoder().decode(Store.self, from: data)
        guard store.version == 1 else { return nil }
        let candidates = store.sessions.filter {
            UUID(uuidString: $0.value.workspaceId) == scope.workspaceID
                && UUID(uuidString: $0.value.surfaceId) == scope.surfaceID
        }
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.key == candidate.value.sessionId,
              let active = store.activeSessionsBySurface.first(where: {
                  UUID(uuidString: $0.key) == scope.surfaceID
              }), active.value.sessionId == candidate.key,
              store.activeSessionsBySurface.filter({
                  UUID(uuidString: $0.key) == scope.surfaceID
              }).count == 1,
              candidate.value.pid == scope.pid,
              candidate.value.pidStartSeconds == scope.pidStartSeconds,
              candidate.value.pidStartMicroseconds == scope.pidStartMicroseconds,
              candidate.value.hookEventName == "Stop",
              candidate.value.turnSettled == true,
              candidate.value.activePromptDepth == 0,
              let proof = candidate.value.shepherdReadiness,
              proof.version == 1, proof.sessionID == candidate.key,
              proof.scope == scope, proof.scope.isValid else { return nil }
        return proof
    }

    private struct Store: Decodable {
        let version: Int
        let sessions: [String: Record]
        let activeSessionsBySurface: [String: Active]
    }

    private struct Active: Decodable {
        let sessionId: String
    }

    private struct Record: Decodable {
        let sessionId: String
        let workspaceId: String
        let surfaceId: String
        let pid: Int32?
        let pidStartSeconds: Int64?
        let pidStartMicroseconds: Int64?
        let hookEventName: String?
        let turnSettled: Bool?
        let activePromptDepth: Int?
        let shepherdReadiness: ShepherdHookReadinessProof?
    }
}
