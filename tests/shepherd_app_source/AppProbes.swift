import CmuxControlSocket
import CmuxTerminal
import Foundation

func agentLiveProcessIdentity(pid: Int32) -> (ttyDevice: Int64?, scopeCacheKey: Int)? { nil }

@MainActor final class TerminalPanel {
    let id = UUID()
    let surface: TerminalSurface
    init(workspaceID: UUID) { surface = TerminalSurface(workspaceID: workspaceID) }
}
@MainActor final class Workspace {
    var id = UUID()
    var panels: [UUID: AnyObject] = [:]
}
@MainActor final class AppDelegate {
    static var shared: AppDelegate?
    let workspace: Workspace
    init(workspace: Workspace) { self.workspace = workspace }
    func workspaceContainingPanel(panelId: UUID, preferredWorkspaceId: UUID?) -> (workspace: Workspace, panel: AnyObject)? {
        // The real lookup may return another workspace; the adapter must check.
        guard let panel = workspace.panels[panelId] else { return nil }
        return (workspace, panel)
    }
}
@MainActor final class TerminalController {
    static let shared = TerminalController()
    nonisolated let transport = SocketTransport()
    nonisolated let socketServer = SocketServerProbe()
    nonisolated static let mobileTaskComposerFeatureEnabled = false
    nonisolated static let v2DebugMethodNames: [String] = []
    lazy var shepherdControlBoundary = makeShepherdControlBoundary()
    static func agentPromptInputState(of surface: TerminalSurface) -> Composer { .empty }
    enum Composer { case unknown, empty, draft(String), dialog }
}

struct SocketServerProbe: Sendable {
    let currentSocketPath = "/tmp/not-a-running-cmux.sock"
    let accessMode = Mode()
    struct Mode: Sendable { let rawValue = "test" }
}
enum CmuxFeatureFlags {
    static let mobileWorkspaceChangesFlag = "test"
    static func offMainEffectiveValue(for flag: String) -> Bool { false }
}
enum MobileHostService {
    static let mobileHostCapabilities: [String: Any] = [:]
}
final class CmuxEventBus {
    static let shared = CmuxEventBus()
    private var events: [[String: Any]] = []
    func resetForTesting() { events = [] }
    func retainedSnapshot() -> [[String: Any]] { events }
    func publish(name: String, category: String, source: String, workspaceId: String? = nil,
                 surfaceId: String? = nil, paneId: String? = nil, windowId: String? = nil,
                 payload: [String: Any]) { events.append(payload) }
}
