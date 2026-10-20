import Foundation

protocol Panel: AnyObject {}
struct PanelStableSurfaceIdentity {}
enum PanelType { case agentSession }
enum WorkspaceAttentionFlashReason { case fixture }
enum AgentSessionRendererKind: String {
    case react, solid
    var displayName: String { rawValue }
}
enum AgentSessionProviderID: String {
    case copilot, codex, claude
    var displayName: String { rawValue }
}
struct AgentSessionWebTheme {}
enum AgentSessionManagedShepherdBoundary { struct Target {} }

@MainActor final class AgentSessionWebRendererCoordinator {
    static var onRevoke: (() -> Void)?
    static var operations: [String] = []
    var onHasActiveProviderChanged: ((Bool) -> Void)?
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)?
    var onRunCommand: ((String) throws -> [String: Any])?

    func bind(
        panelId: UUID, workspaceId: UUID, rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID, workingDirectory: String?,
        theme: AgentSessionWebTheme, isFocused: Bool
    ) {}
    func prepareNativeCodingStart(
        panelId: UUID, workspaceId: UUID, rendererKind: AgentSessionRendererKind,
        workingDirectory: String, executableURL: URL,
        isCurrentOwner: @escaping @MainActor () -> Bool
    ) throws {}
    func focus() {}
    func unfocus() {}
    func managedShepherdTarget() -> AgentSessionManagedShepherdBoundary.Target? { nil }
    func revokeNativeCodingStart() {
        Self.operations.append("revoke")
        Self.onRevoke?()
    }
    func close() { Self.operations.append("close") }
}

@main struct NativePanelFixture {
    @MainActor static func main() {
        let panel = AgentSessionPanel(
            workspaceId: UUID(), rendererKind: .react, initialProviderID: .copilot,
            workingDirectory: "/controlled/project"
        )
        let workspace = panel.workspaceId
        AgentSessionWebRendererCoordinator.onRevoke = { [weak panel] in
            precondition(panel?.workspaceId == workspace, "revocation followed the workspace mutation")
            precondition(panel?.workingDirectory == "/controlled/project", "revocation followed the CWD mutation")
            precondition(panel?.currentProviderID == .copilot, "revocation followed the provider mutation")
        }
        switch CommandLine.arguments.last {
        case "workspace":
            let next = UUID()
            panel.updateWorkspaceId(next)
            precondition(panel.workspaceId == next)
            precondition(AgentSessionWebRendererCoordinator.operations == ["revoke"])
        case "directory":
            panel.clearWorkingDirectory()
            precondition(panel.workingDirectory == nil)
            precondition(AgentSessionWebRendererCoordinator.operations == ["revoke"])
        case "provider":
            panel.rendererSession.onProviderIDChanged?(.claude)
            precondition(panel.currentProviderID == .claude)
            precondition(AgentSessionWebRendererCoordinator.operations == ["revoke"])
        case "close":
            panel.close()
            precondition(AgentSessionWebRendererCoordinator.operations == ["revoke", "close"])
        case "noop":
            panel.updateWorkspaceId(workspace)
            panel.rendererSession.onProviderIDChanged?(.copilot)
            precondition(AgentSessionWebRendererCoordinator.operations.isEmpty)
        default:
            preconditionFailure("unknown scenario")
        }
    }
}
