import CmuxControlSocket
import Foundation

struct CLIError: Error { let message: String }

struct ClaudeHookSessionRecord {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var pid: Int?
    var pidStartSeconds: Int64?
    var pidStartMicroseconds: Int64?
    var turnSettled: Bool?
    var hookEventName: String?
    var activePromptDepth: Int?
    var shepherdReadiness: ShepherdHookReadinessProof?
    var shepherdWorkRevision: UUID?
    var shepherdProducer: ShepherdHookProducerState? = nil
    var updatedAt: TimeInterval = 0
}

struct ClaudeHookActiveSessionRecord {
    var sessionId: String
    var updatedAt: TimeInterval = 0
}
struct ClaudeHookSessionStoreFile {
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsBySurface: [String: ClaudeHookActiveSessionRecord] = [:]
    var decodeDiagnostics = Diagnostics()
    struct Diagnostics { var droppedCount = 0 }
}

final class ClaudeHookSessionStore {
    var state = ClaudeHookSessionStoreFile()
    var failPersistence = false
    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? { state.sessions[sessionId] }
    func withLockedState<T>(
        deadline: Date? = nil,
        persist: Bool = true,
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> T {
        var staged = state
        let result = try body(&staged)
        if persist {
            if failPersistence { throw CLIError(message: "Injected persistence failure") }
            state = staged
        }
        return result
    }
    func makeSessionRecord(
        state: ClaudeHookSessionStoreFile, sessionId: String, workspaceId: String,
        surfaceId: String, now: TimeInterval
    ) -> ClaudeHookSessionRecord {
        state.sessions[sessionId] ?? ClaudeHookSessionRecord(
            sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId,
            pid: nil, pidStartSeconds: nil, pidStartMicroseconds: nil,
            turnSettled: nil, hookEventName: nil, activePromptDepth: nil,
            shepherdReadiness: nil, shepherdWorkRevision: nil, updatedAt: now
        )
    }
}
