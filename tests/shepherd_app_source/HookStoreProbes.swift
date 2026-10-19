import CmuxControlSocket
import Foundation

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
}

struct ClaudeHookActiveSessionRecord { var sessionId: String }
struct ClaudeHookSessionStoreFile {
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsBySurface: [String: ClaudeHookActiveSessionRecord] = [:]
    var decodeDiagnostics = Diagnostics()
    struct Diagnostics { var droppedCount = 0 }
}

final class ClaudeHookSessionStore {
    var state = ClaudeHookSessionStoreFile()
    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? { state.sessions[sessionId] }
    func withLockedState<T>(
        _ body: (inout ClaudeHookSessionStoreFile) throws -> T
    ) throws -> T { try body(&state) }
}
