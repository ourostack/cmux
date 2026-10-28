import Foundation

@MainActor
final class AgentSessionWebRendererSession {
    private let ownedCoordinator: AgentSessionWebRendererCoordinator

    init(managedProviderID: AgentSessionProviderID? = nil) {
        ownedCoordinator = AgentSessionWebRendererCoordinator(managedProviderID: managedProviderID)
    }
    var onHasActiveProviderChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onHasActiveProviderChanged = onHasActiveProviderChanged
        }
    }
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)? {
        didSet {
            ownedCoordinator.onProviderIDChanged = onProviderIDChanged
        }
    }
    var onRunCommand: ((String) throws -> [String: Any])? {
        didSet {
            ownedCoordinator.onRunCommand = onRunCommand
        }
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID,
        workingDirectory: String?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> AgentSessionWebRendererCoordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            workingDirectory: workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    func managedShepherdTarget() -> AgentSessionManagedShepherdBoundary.Target? {
        ownedCoordinator.managedShepherdTarget()
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func prepareNativeCodingStart(
        panelId: UUID, workspaceId: UUID, rendererKind: AgentSessionRendererKind,
        workingDirectory: String, executableURL: URL,
        providerID: AgentSessionProviderID = .copilot,
        isCurrentOwner: @escaping @MainActor () -> Bool
    ) throws {
        try ownedCoordinator.prepareNativeCodingStart(
            panelId: panelId, workspaceId: workspaceId, rendererKind: rendererKind,
            workingDirectory: workingDirectory, executableURL: executableURL,
            providerID: providerID, isCurrentOwner: isCurrentOwner
        )
    }

    func revokeNativeCodingStart() {
        ownedCoordinator.revokeNativeCodingStart()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
    }

    func close() {
        ownedCoordinator.close()
    }
}
