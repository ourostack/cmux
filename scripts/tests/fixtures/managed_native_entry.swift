import Darwin
import Foundation

protocol Panel: AnyObject {}
struct PanelStableSurfaceIdentity {}
enum PanelType { case agentSession }
enum WorkspaceAttentionFlashReason { case fixture }
typealias PaneID = UUID
enum AgentSessionRendererKind: String, Codable, Sendable {
    case react, solid
    var displayName: String { rawValue }
}
enum ShepherdManagedProvider: String { case copilot, codex, claude }
struct AgentSessionWebTheme: Equatable {}
enum AgentSessionBridgeError: Error {
    case invalidRequest
    case unsupportedTransport(String)
    case sessionAlreadyRunning
}
final class WKWebView { var url = URL(fileURLWithPath: "/controlled/shell.html") }
final class WKNavigation {}

@MainActor final class AgentSessionManagedCopilotLaunch {
    struct Scope {
        let surfaceID: UUID
        let workspaceID: UUID
    }
    @MainActor final class NativeCodingOwner {
        static let executionDisclosure = "Controlled foreground coding disclosure."
        let scope: Scope
        let provider: ShepherdManagedProvider
        let rendererID: String
        let workingDirectory: String
        let projectMandate = UUID()
        let isCurrentOwner: @MainActor () -> Bool
        var revoked = false
        var isCurrent: Bool { !revoked && isCurrentOwner() }
        private init(
            panelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
            isCurrentOwner: @escaping @MainActor () -> Bool,
            provider: ShepherdManagedProvider
        ) {
            scope = Scope(surfaceID: panelID, workspaceID: workspaceID)
            self.rendererID = rendererID
            self.workingDirectory = workingDirectory
            self.isCurrentOwner = isCurrentOwner
            self.provider = provider
        }
        static func issueForFreshNativePanel(
            newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
            owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool,
            provider: ShepherdManagedProvider = .copilot
        ) -> NativeCodingOwner? {
            guard isCurrentOwner(),
                  let directory = try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory) else { return nil }
            return NativeCodingOwner(
                panelID: newPanelID, workspaceID: workspaceID, rendererID: rendererID,
                workingDirectory: directory, isCurrentOwner: isCurrentOwner, provider: provider
            )
        }
        func revoke() { revoked = true }
    }
// __CANONICAL_METHOD__
}

typealias AgentSessionManagedNativeOwner = AgentSessionManagedCopilotLaunch.NativeCodingOwner

@MainActor final class AgentSessionProcessStore {
    struct Started { let sessionId = UUID().uuidString }
    enum ControlledFailure: Error { case nativeProfileUnqualified }
    var hasActiveProviderSession = false
    var starts = 0
    var manualStarts = 0
    var nativeManagedSessionSnapshot: [String: Any]? { nil }
    var hold = false
    var held: CheckedContinuation<Void, Never>?
    var fail = false
    var receivedOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var receivedProvider: AgentSessionProviderID?
    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)?
    func startManagedCopilot(
        scope: AgentSessionManagedCopilotLaunch.Scope, executableURL: URL, workingDirectory: String,
        codingProjectMandate: UUID,
        nativeCodingOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner
    ) async throws -> Started {
        precondition(nativeCodingOwner.provider == .copilot, "Codex owner entered Copilot")
        receivedProvider = .copilot
        return try await start(scope: scope, workingDirectory: workingDirectory,
                               codingProjectMandate: codingProjectMandate, nativeCodingOwner: nativeCodingOwner)
    }
    func startManagedCodex(
        scope: AgentSessionManagedCopilotLaunch.Scope, executableURL: URL, workingDirectory: String,
        nativeCodingOwner: AgentSessionManagedNativeOwner
    ) async throws -> Started {
        precondition(nativeCodingOwner.provider == .codex, "Copilot owner entered Codex")
        receivedProvider = .codex
        return try await start(scope: scope, workingDirectory: workingDirectory,
                               codingProjectMandate: nativeCodingOwner.projectMandate, nativeCodingOwner: nativeCodingOwner)
    }
    private func start(
        scope: AgentSessionManagedCopilotLaunch.Scope, workingDirectory: String,
        codingProjectMandate: UUID, nativeCodingOwner: AgentSessionManagedNativeOwner
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
    func start(plan: AgentExecutableResolver.Plan, workingDirectory: String?) async throws -> Started {
        manualStarts += 1
        hasActiveProviderSession = true
        return Started()
    }
}

struct AgentExecutableResolver {
    struct Plan { let executableURL = URL(fileURLWithPath: "/controlled/manual"); let arguments: [String] = [] }
    static func cmuxConfiguredExecutablePaths() -> [String: String] { [:] }
    init(configuredExecutablePaths: [String: String]) {}
    func resolve(_ provider: AgentSessionProviderID) throws -> Plan { Plan() }
}
struct ControlledProviderRequest {
    let provider: AgentSessionProviderID
    func providerID() throws -> AgentSessionProviderID { provider }
    func string(_ key: String) -> String? { nil }
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
    let managedProviderID: AgentSessionProviderID?
    var managedRendererController: AgentSessionManagedRendererController?
    var trustedShellURL: URL? = URL(fileURLWithPath: "/controlled/shell.html")
    var rendererBindings = 0
    static weak var latest: AgentSessionWebRendererCoordinator?
    init(managedProviderID: AgentSessionProviderID? = nil) {
        self.managedProviderID = managedProviderID
        Self.latest = self
    }
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
    func contextSnapshot() -> [String: Any] {
        var context: [String: Any] = [:]
// __ACTUAL_CONTEXT_TAIL__
    }
    func manualRequest(_ method: String, provider: AgentSessionProviderID) async throws -> [String: Any] {
        let request = ControlledProviderRequest(provider: provider)
        switch method {
// __ACTUAL_MANUAL_PROVIDER_BRANCHES__
        default: throw AgentSessionBridgeError.invalidRequest
        }
    }
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
        workingDirectory: String?, focus: Bool, managedProviderID: AgentSessionProviderID? = nil
    ) -> AgentSessionPanel? {
        creations += 1
        let directory = workingDirectory
// __ACTUAL_PANEL_CONSTRUCTION__
        panels[agentPanel.id] = agentPanel
        onCreate?()
        return agentPanel
    }
    func closePanel(_ id: UUID, force: Bool) -> Bool { panels.removeValue(forKey: id) != nil }
    struct SavedPanel {
        let agentSession: SessionAgentSessionPanelSnapshot?
        let directory: String?
    }
    func applySessionPanelMetadata(_ snapshot: SavedPanel, toPanelId: UUID) {}
    func restore(_ agentSession: SessionAgentSessionPanelSnapshot) -> UUID? {
        let snapshot = SavedPanel(agentSession: agentSession, directory: nil)
        let paneId = UUID()
        let restoresUntrustedSavedDirectory = false
// __ACTUAL_SNAPSHOT_RESTORE__
    }
    func snapshot(_ agentPanel: AgentSessionPanel) -> SessionAgentSessionPanelSnapshot {
        var agentSessionSnapshot: SessionAgentSessionPanelSnapshot?
        let directory = agentPanel.workingDirectory
// __ACTUAL_SNAPSHOT_CONSTRUCTION__
        return agentSessionSnapshot!
    }
// __WORKSPACE_ENTRY_METHODS__
}

@main struct NativeEntryFixture {
    @MainActor static func settle(_ coordinator: AgentSessionWebRendererCoordinator) async {
        await coordinator.nativeCodingStartTask?.value
    }
    @MainActor static func main() async throws {
        let argument = CommandLine.arguments.last!
        let isCodex = argument.hasPrefix("codex-")
        let scenario = isCodex ? String(argument.dropFirst(6)) : argument
        let expectedProvider: AgentSessionProviderID = isCodex ? .codex : .copilot
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-native-entry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let workspace = Workspace(directory: directory.path)
        var selected: Workspace? = workspace
        if scenario == "unsupported-native-provider" {
            for provider in [AgentSessionProviderID.claude, .opencode] {
                let coordinator = AgentSessionWebRendererCoordinator(managedProviderID: provider)
                do {
                    try coordinator.prepareNativeCodingStart(
                        panelId: UUID(), workspaceId: workspace.id, rendererKind: .react,
                        workingDirectory: directory.path, executableURL: URL(fileURLWithPath: "/controlled/provider"),
                        providerID: provider, isCurrentOwner: { true }
                    )
                    preconditionFailure("Unsupported native provider was accepted")
                } catch AgentSessionBridgeError.unsupportedTransport(let reason) {
                    precondition(reason == "managed-native-provider")
                }
                precondition(coordinator.nativeCodingOwner == nil)
                precondition(coordinator.pendingNativeCodingExecutable == nil)
                precondition(!coordinator.isProviderStartPending && coordinator.processStore.starts == 0)
            }
            return
        }
        @MainActor func createPanel(renderer: AgentSessionRendererKind = .react) throws -> AgentSessionPanel {
            if isCodex {
                return try workspace.newManagedCodexSessionSurface(
                    inPane: UUID(), rendererKind: renderer, executableURL: URL(fileURLWithPath: "/controlled/provider"),
                    currentWorkspace: { selected }
                )
            }
            return try workspace.newManagedCopilotSessionSurface(
                inPane: UUID(), rendererKind: renderer, executableURL: URL(fileURLWithPath: "/controlled/provider"),
                currentWorkspace: { selected }
            )
        }
        if scenario == "restore-intent" || scenario == "legacy-restore" {
            var saved: [String: Any] = [
                "rendererKind": "react", "providerID": scenario == "legacy-restore" ? "codex" : expectedProvider.rawValue,
                "workingDirectory": directory.path,
            ]
            if scenario != "legacy-restore" { saved["managedProviderID"] = expectedProvider.rawValue }
            let decoded = try JSONDecoder().decode(
                SessionAgentSessionPanelSnapshot.self, from: JSONSerialization.data(withJSONObject: saved)
            )
            let restoredID = workspace.restore(decoded)!
            precondition(workspace.panels[restoredID] != nil)
            let coordinator = AgentSessionWebRendererCoordinator.latest!
            let intent = coordinator.contextSnapshot()["nativeManagedIntent"] as? [String: Any]
            precondition(coordinator.nativeCodingOwner == nil && coordinator.pendingNativeCodingExecutable == nil)
            precondition(coordinator.processStore.starts == 0)
            if scenario == "legacy-restore" {
                precondition(intent == nil)
                _ = try await coordinator.manualRequest("provider.start", provider: .codex)
                precondition(coordinator.processStore.manualStarts == 1)
            } else {
                precondition(intent?["providerId"] as? String == expectedProvider.rawValue,
                             "CMUX_NATIVE_MANAGED_INTENT_UNAVAILABLE: restored managed intent lost")
                precondition(intent?["status"] as? String == "unavailable")
                do {
                    _ = try await coordinator.manualRequest("provider.start", provider: .codex)
                    preconditionFailure("CMUX_NATIVE_MANAGED_INTENT_UNAVAILABLE: restored panel started manual")
                } catch AgentSessionBridgeError.unsupportedTransport(let reason) {
                    precondition(reason == "managed-native-intent")
                }
            }
            return
        }
        if scenario == "creation-owner-lost" {
            workspace.onCreate = { selected = nil }
            do {
                _ = try createPanel()
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
                _ = try createPanel()
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
        if ["ordinary", "manual-reservation", "ordinary-manual-start"].contains(scenario) {
            panel = AgentSessionPanel(workspaceId: workspace.id, rendererKind: .react)
        } else {
            panel = try createPanel(renderer: scenario == "solid" ? .solid : .react)
            precondition(panel.currentProviderID == expectedProvider, "fresh panel selected the wrong provider")
        }
        let coordinator = AgentSessionWebRendererCoordinator.latest!
        precondition(coordinator.processStore.starts == 0)
        if !["ordinary", "manual-reservation", "ordinary-manual-start"].contains(scenario) {
            precondition(coordinator.initialProviderID == expectedProvider, "pending entry changed the provider")
        }
        if scenario == "retained-intent" || scenario == "snapshot-intent" {
            let intent = coordinator.contextSnapshot()["nativeManagedIntent"] as? [String: Any]
            precondition(intent?["providerId"] as? String == expectedProvider.rawValue,
                         "CMUX_NATIVE_MANAGED_INTENT_UNAVAILABLE: fresh managed intent missing")
            precondition(intent?["status"] as? String == "starting")
            if scenario == "snapshot-intent" {
                let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.snapshot(panel))) as! [String: Any]
                precondition(saved["managedProviderID"] as? String == expectedProvider.rawValue,
                             "CMUX_NATIVE_MANAGED_INTENT_UNAVAILABLE: saved managed intent missing")
            }
            coordinator.revokeNativeCodingStart()
            let revoked = coordinator.contextSnapshot()["nativeManagedIntent"] as? [String: Any]
            precondition(revoked?["providerId"] as? String == expectedProvider.rawValue)
            precondition(revoked?["status"] as? String == "unavailable")
            precondition(coordinator.processStore.starts == 0)
            return
        }
        if scenario == "managed-manual-refusal" || scenario == "ordinary-manual-start" {
            coordinator.revokeNativeCodingStart()
            for method in ["provider.select", "provider.start"] {
                if scenario == "ordinary-manual-start" {
                    _ = try await coordinator.manualRequest(method, provider: .codex)
                } else {
                    do {
                        _ = try await coordinator.manualRequest(method, provider: .codex)
                        preconditionFailure("CMUX_NATIVE_MANAGED_INTENT_UNAVAILABLE: managed panel accepted manual request")
                    } catch AgentSessionBridgeError.unsupportedTransport(let reason) {
                        precondition(reason == "managed-native-intent")
                    }
                }
            }
            precondition(coordinator.processStore.manualStarts == (scenario == "ordinary-manual-start" ? 1 : 0))
            return
        }
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
                initialProviderID: scenario == "bind-provider" ? .claude : expectedProvider,
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
            precondition(owner.provider.rawValue == expectedProvider.rawValue, "issued owner selected the wrong provider")
            precondition(coordinator.processStore.receivedProvider == expectedProvider, "native start used the wrong Store entry")
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
