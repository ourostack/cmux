import Darwin
import Foundation

protocol Panel: AnyObject {}
struct PanelStableSurfaceIdentity {}
enum PanelType { case agentSession }
enum WorkspaceAttentionFlashReason { case fixture }
typealias PaneID = UUID
enum AgentSessionRendererKind: String {
    case react, solid
    var displayName: String { rawValue }
}
enum AgentSessionProviderID: String {
    case copilot, codex, claude
    var displayName: String { rawValue }
}
struct AgentSessionWebTheme: Equatable {}
enum AgentSessionBridgeError: Error {
    case invalidRequest
    case unsupportedTransport(String)
}
final class WKWebView { var url = URL(fileURLWithPath: "/controlled/shell.html") }
final class WKNavigation {}

@MainActor final class AgentSessionManagedCopilotLaunch {
    struct Scope {
        let surfaceID: UUID
        let workspaceID: UUID
    }
    @MainActor final class NativeCodingOwner {
        let scope: Scope
        let rendererID: String
        let workingDirectory: String
        let projectMandate = UUID()
        let isCurrentOwner: @MainActor () -> Bool
        var revoked = false
        var isCurrent: Bool { !revoked && isCurrentOwner() }
        private init(
            panelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
            isCurrentOwner: @escaping @MainActor () -> Bool
        ) {
            scope = Scope(surfaceID: panelID, workspaceID: workspaceID)
            self.rendererID = rendererID
            self.workingDirectory = workingDirectory
            self.isCurrentOwner = isCurrentOwner
        }
        static func issueForFreshNativePanel(
            newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
            owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool
        ) -> NativeCodingOwner? {
            guard isCurrentOwner(),
                  let directory = try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory) else { return nil }
            return NativeCodingOwner(
                panelID: newPanelID, workspaceID: workspaceID, rendererID: rendererID,
                workingDirectory: directory, isCurrentOwner: isCurrentOwner
            )
        }
        func revoke() { revoked = true }
    }
// __CANONICAL_METHOD__
}

@MainActor final class AgentSessionProcessStore {
    struct Started { let sessionId = UUID().uuidString }
    enum ControlledFailure: Error { case nativeProfileUnqualified }
    var hasActiveProviderSession = false
    var starts = 0
    var hold = false
    var held: CheckedContinuation<Void, Never>?
    var fail = false
    var receivedOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)?
    func startManagedCopilot(
        scope: AgentSessionManagedCopilotLaunch.Scope, executableURL: URL, workingDirectory: String,
        codingProjectMandate: UUID,
        nativeCodingOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner
    ) async throws -> Started {
        starts += 1
        receivedOwner = nativeCodingOwner
        precondition(nativeCodingOwner.isCurrent)
        precondition(workingDirectory == nativeCodingOwner.workingDirectory)
        precondition(scope.surfaceID == nativeCodingOwner.scope.surfaceID)
        precondition(scope.workspaceID == nativeCodingOwner.scope.workspaceID)
        precondition(codingProjectMandate == nativeCodingOwner.projectMandate)
        if hold { await withCheckedContinuation { held = $0 } }
        try Task.checkCancellation()
        if fail { throw ControlledFailure.nativeProfileUnqualified }
        hasActiveProviderSession = true
        return Started()
    }
}

@MainActor final class AgentSessionManagedRendererController {
    func invalidate() {}
    func invalidateRender() {}
}

enum AgentSessionManagedShepherdBoundary { struct Target {} }

@MainActor final class AgentSessionTurnNotifier {
    init(surfaceID: UUID, workspaceID: () -> UUID, workingDirectory: () -> String?) {}
    func observe(_ event: [String: Any]) {}
}

@MainActor final class AgentSessionWebRendererCoordinator {
    var onHasActiveProviderChanged: ((Bool) -> Void)?
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)?
    var onRunCommand: ((String) throws -> [String: Any])?
    var isClosed = false
    var webView: WKWebView?
    var panelId = UUID()
    var workspaceId = UUID()
    var rendererKind: AgentSessionRendererKind = .react
    var initialProviderID: AgentSessionProviderID = .codex
    var workingDirectory: String?
    var providerWorkingDirectory: String?
    var hasFinishedNavigation = false
    var isPanelFocused = false
    var theme = AgentSessionWebTheme()
    var loadedRendererKind: AgentSessionRendererKind?
    var turnNotifier: AgentSessionTurnNotifier?
    var turnNotifierPanelId: UUID?
    var isProviderStartPending = false
    var processStore = AgentSessionProcessStore()
    var nativeCodingOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var pendingNativeCodingExecutable: URL?
    var nativeCodingStartTask: Task<Void, Never>?
    var nativeContextRequested = false
    var managedRendererController: AgentSessionManagedRendererController?
    var trustedShellURL: URL? = URL(fileURLWithPath: "/controlled/shell.html")
    var rendererBindings = 0
    static weak var latest: AgentSessionWebRendererCoordinator?
    init() { Self.latest = self }
// __BIND_METHOD__
    func applyThemeToLoadedPage() {}
    func sendEvent(_ event: [String: Any]) {}
    func managedShepherdTarget() -> AgentSessionManagedShepherdBoundary.Target? { nil }
    func focus() {}
    func unfocus() {}
    func close() { revokeNativeCodingStart(); isClosed = true }
    static func isTrustedShellURL(_ url: URL?, expected: URL?) -> Bool { url == expected }
    func managedRenderer(
        for owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner
    ) -> AgentSessionManagedRendererController? {
        rendererBindings += 1
        return nil
    }
    func receiveContext() {
// __CONTEXT_REQUEST_BODY__
    }
    func finishNavigation() {
        webView = WKWebView()
        hasFinishedNavigation = true
        startPendingNativeCodingIfReady()
    }
    func resetVisiblePaintState() {}
// __NAVIGATION_START_METHOD__
// __PROCESS_TERMINATION_METHOD__
// __NATIVE_ENTRY_METHODS__
}

@MainActor final class Workspace {
    let id: UUID
    var panels: [UUID: any Panel] = [:]
    var isRetiredFromOwningTabManager = false
    var usesRemoteDirectoryProvenance = false
    var cloudVMBinding: String?
// __REMOTE_REPORT_PROPERTY__
    func insertRemoteReport(_ id: UUID) { remoteDirectoryReportPanelIds.insert(id) }
    func discardRemoteReports() { remoteDirectoryReportPanelIds.removeAll() }
    var focusedPanelId: UUID?
    var currentDirectory: String {
// __CURRENT_DIRECTORY_WILL_SET__
    }
    var remoteConfiguration: String? {
// __REMOTE_WILL_SET__
    }
    var isRemoteWorkspace: Bool { remoteConfiguration != nil }
    var creations = 0
    var onCreate: (() -> Void)?
    init(directory: String, id: UUID = UUID()) { currentDirectory = directory; self.id = id }
    func newAgentSessionSurface(
        inPane: PaneID, providerID: AgentSessionProviderID, rendererKind: AgentSessionRendererKind,
        workingDirectory: String, focus: Bool
    ) -> AgentSessionPanel? {
        creations += 1
        let panel = AgentSessionPanel(
            workspaceId: id, rendererKind: rendererKind, initialProviderID: providerID,
            workingDirectory: workingDirectory
        )
        panels[panel.id] = panel
        onCreate?()
        return panel
    }
    func closePanel(_ id: UUID, force: Bool) -> Bool { panels.removeValue(forKey: id) != nil }
// __WORKSPACE_ENTRY_METHODS__
}

@main struct NativeEntryFixture {
    @MainActor static func settle(_ coordinator: AgentSessionWebRendererCoordinator) async {
        await coordinator.nativeCodingStartTask?.value
    }
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments.last!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-native-entry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let workspace = Workspace(directory: directory.path)
        var selected: Workspace? = workspace
        if scenario == "creation-owner-lost" {
            workspace.onCreate = { selected = nil }
            do {
                _ = try workspace.newManagedCopilotSessionSurface(
                    inPane: UUID(), rendererKind: .react, executableURL: URL(fileURLWithPath: "/controlled/provider"),
                    currentWorkspace: { selected }
                )
                preconditionFailure("lost native owner accepted")
            } catch {
                precondition(workspace.creations == 1)
                precondition(workspace.panels.isEmpty)
                precondition(AgentSessionWebRendererCoordinator.latest == nil)
            }
            return
        }
        if ["remote", "remote-provenance", "cloud", "remote-report", "retired", "not-current", "file-directory"].contains(scenario) {
            if scenario == "remote" { workspace.remoteConfiguration = "controlled" }
            if scenario == "remote-provenance" { workspace.usesRemoteDirectoryProvenance = true }
            if scenario == "cloud" { workspace.cloudVMBinding = "controlled" }
            if scenario == "remote-report" { workspace.insertRemoteReport(UUID()) }
            if scenario == "retired" { workspace.isRetiredFromOwningTabManager = true }
            if scenario == "not-current" { selected = Workspace(directory: directory.path) }
            if scenario == "file-directory" {
                let file = directory.appendingPathComponent("not-a-directory")
                try Data("controlled".utf8).write(to: file)
                workspace.currentDirectory = file.path
            }
            do {
                _ = try workspace.newManagedCopilotSessionSurface(
                    inPane: UUID(), rendererKind: .react, executableURL: URL(fileURLWithPath: "/controlled/provider"),
                    currentWorkspace: { selected }
                )
                preconditionFailure("nonlocal or noncurrent entry accepted")
            } catch {
                precondition(workspace.creations == 0)
                precondition(workspace.panels.isEmpty)
            }
            return
        }
        if scenario == "canonical-directory" {
            let link = directory.appendingPathComponent("project-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            workspace.currentDirectory = link.path
        }
        let panel: AgentSessionPanel
        if ["ordinary", "manual-reservation"].contains(scenario) {
            panel = AgentSessionPanel(workspaceId: workspace.id, rendererKind: .react)
        } else {
            panel = try workspace.newManagedCopilotSessionSurface(
                inPane: UUID(), rendererKind: scenario == "solid" ? .solid : .react,
                executableURL: URL(fileURLWithPath: "/controlled/provider"),
                currentWorkspace: { selected }
            )
        }
        let coordinator = AgentSessionWebRendererCoordinator.latest!
        precondition(coordinator.processStore.starts == 0)
        if scenario == "untrusted-shell" {
            coordinator.webView = WKWebView()
            coordinator.webView?.url = URL(fileURLWithPath: "/controlled/untrusted.html")
            coordinator.hasFinishedNavigation = true
            coordinator.receiveContext()
            await settle(coordinator)
            precondition(coordinator.processStore.starts == 0)
            precondition(coordinator.pendingNativeCodingExecutable != nil)
            return
        }
        if scenario == "manual-reservation" {
            coordinator.isProviderStartPending = true
            coordinator.revokeNativeCodingStart()
            precondition(coordinator.isProviderStartPending)
            return
        }
        if scenario == "late-task" {
            coordinator.processStore.hold = true
            coordinator.receiveContext()
            coordinator.finishNavigation()
            while coordinator.processStore.held == nil { await Task.yield() }
            let task = coordinator.nativeCodingStartTask!
            coordinator.revokeNativeCodingStart()
            coordinator.isProviderStartPending = true
            coordinator.processStore.held?.resume()
            await task.value
            precondition(coordinator.isProviderStartPending, "stale native defer cleared the new manual start")
            precondition(coordinator.rendererBindings == 0)
            return
        }
        let invalidated = [
            "other-workspace", "missing-panel", "close", "workspace-id", "directory", "provider",
            "project-root", "remote-transition", "navigation-reload", "web-process-exit",
            "bind-panel", "bind-workspace", "bind-renderer", "bind-directory", "bind-provider",
            "replacement-workspace",
            "remote-provenance-aba",
        ].contains(scenario)
        if scenario == "other-workspace" { selected = Workspace(directory: directory.path) }
        if scenario == "replacement-workspace" { selected = Workspace(directory: directory.path, id: workspace.id) }
        if scenario == "missing-panel" { workspace.panels.removeValue(forKey: panel.id) }
        if scenario == "close" { panel.close() }
        if scenario == "workspace-id" { panel.updateWorkspaceId(UUID()) }
        if scenario == "directory" { panel.clearWorkingDirectory() }
        if scenario == "provider" { panel.rendererSession.onProviderIDChanged?(.claude) }
        if scenario == "project-root" { workspace.currentDirectory = directory.deletingLastPathComponent().path }
        if scenario == "remote-transition" { workspace.remoteConfiguration = "controlled" }
        if scenario == "remote-provenance-aba" {
            workspace.insertRemoteReport(UUID())
            workspace.discardRemoteReports()
        }
        if scenario == "navigation-reload" {
            coordinator.receiveContext()
            coordinator.webView(WKWebView(), didStartProvisionalNavigation: WKNavigation())
        }
        if scenario == "web-process-exit" { coordinator.webViewWebContentProcessDidTerminate(WKWebView()) }
        if scenario == "start-failed" { coordinator.processStore.fail = true }
        if scenario.hasPrefix("bind-") {
            coordinator.bind(
                panelId: scenario == "bind-panel" ? UUID() : panel.id,
                workspaceId: scenario == "bind-workspace" ? UUID() : panel.workspaceId,
                rendererKind: scenario == "bind-renderer" ? .solid : panel.rendererKind,
                initialProviderID: scenario == "bind-provider" ? .claude : .copilot,
                workingDirectory: scenario == "bind-directory" ? "/" : panel.workingDirectory,
                theme: AgentSessionWebTheme(), isFocused: true
            )
        }
        if scenario == "navigation-first" {
            coordinator.finishNavigation()
            precondition(coordinator.processStore.starts == 0)
            coordinator.receiveContext()
        } else {
            coordinator.receiveContext()
            precondition(coordinator.processStore.starts == 0)
            coordinator.finishNavigation()
        }
        await settle(coordinator)
        if scenario == "repeat" || scenario == "start-failed" {
            coordinator.receiveContext()
            coordinator.finishNavigation()
            await settle(coordinator)
        }
        if invalidated || scenario == "ordinary" {
            precondition(coordinator.processStore.starts == 0, "unowned or invalidated entry started")
            precondition(coordinator.rendererBindings == 0)
        } else {
            precondition(coordinator.processStore.starts == 1, "native request did not start exactly once")
            let owner = coordinator.processStore.receivedOwner!
            precondition(owner.rendererID == (scenario == "solid" ? "solid" : "react"))
            let canonicalDirectory = try AgentSessionManagedCopilotLaunch.canonicalPath(directory.path)
            precondition(owner.workingDirectory == canonicalDirectory)
            if scenario == "start-failed" {
                precondition(owner.revoked)
                precondition(coordinator.rendererBindings == 0)
            } else {
                precondition(coordinator.rendererBindings == 1)
            }
        }
    }
}
