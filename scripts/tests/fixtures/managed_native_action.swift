import Foundation
import SwiftUI

enum AgentSessionRendererKind: String { case react, solid }
enum ShepherdManagedProvider: String { case copilot, codex, claude }
enum AgentSessionBridgeError: Error { case invalidRequest, unsupportedTransport(String) }
typealias PaneID = UUID

@MainActor final class AgentSessionManagedNativeOwner {
    static var qualifiedProvider: ShepherdManagedProvider?
    static var qualifiedRenderer = "react"
    static let executionDisclosure = "Controlled native disclosure."
    static func hasQualifiedNativeProfile(
        rendererID: String, provider: ShepherdManagedProvider = .copilot
    ) -> Bool { provider == qualifiedProvider && rendererID == qualifiedRenderer }
}
enum AgentSessionManagedCopilotLaunch { typealias NativeCodingOwner = AgentSessionManagedNativeOwner }

@MainActor final class NSAlert {
    enum Response { case alertFirstButtonReturn, alertSecondButtonReturn }
    static var response: Response = .alertFirstButtonReturn
    static var afterDisclosure: (() -> Void)?
    static var disclosures = 0
    static var errors = 0
    static var disclosedTitle = ""
    private let isError: Bool
    var messageText = ""
    var informativeText = ""
    init() { isError = false }
    init(error: Error) { isError = true }
    func addButton(withTitle: String) {}
    @discardableResult func runModal() -> Response {
        if isError {
            Self.errors += 1
        } else {
            Self.disclosures += 1
            Self.disclosedTitle = messageText
            precondition(informativeText == AgentSessionManagedNativeOwner.executionDisclosure)
            Self.afterDisclosure?()
        }
        return Self.response
    }
}

@MainActor final class Bundle {
    static let main = Bundle()
    static var lookups = 0
    static var missing = false
    func url(forResource name: String, withExtension ext: String?, subdirectory: String?) -> URL? {
        Self.lookups += 1
        precondition(name == "cmux-managed-codex-host" && ext == nil && subdirectory == "bin",
                     "Managed Codex must select only our owned bundled backend")
        return Self.missing ? nil : URL(fileURLWithPath: "/controlled/bundle/bin/cmux-managed-codex-host")
    }
}

@MainActor struct AgentExecutableResolver {
    struct Plan { let executableURL: URL }
    static var configurations = 0
    static var resolutions = 0
    static func cmuxConfiguredExecutablePaths() -> [String: String] {
        configurations += 1
        return [:]
    }
    init(configuredExecutablePaths: [String: String]) {}
    func resolve(_ provider: AgentSessionProviderID) throws -> Plan {
        Self.resolutions += 1
        precondition(provider == .copilot, "Managed Codex fell back to the ordinary CLI resolver")
        return Plan(executableURL: URL(fileURLWithPath: "/controlled/copilot"))
    }
}

@MainActor final class ControlledPanes {
    var focusedPaneId: PaneID? = UUID()
    var allPaneIds: [PaneID] = []
}
@MainActor final class Workspace {
    let bonsplitController = ControlledPanes()
    var provider: AgentSessionProviderID?
    var renderer: AgentSessionRendererKind?
    var executable: URL?
    var currentOwner: (() -> Workspace?)?
    func newManagedCopilotSessionSurface(
        inPane: PaneID, rendererKind: AgentSessionRendererKind, executableURL: URL,
        currentWorkspace: @escaping @MainActor () -> Workspace?
    ) throws {
        precondition(currentWorkspace() === self)
        provider = .copilot; renderer = rendererKind; executable = executableURL; currentOwner = currentWorkspace
    }
    func newManagedCodexSessionSurface(
        inPane: PaneID, rendererKind: AgentSessionRendererKind, executableURL: URL,
        currentWorkspace: @escaping @MainActor () -> Workspace?
    ) throws {
        precondition(currentWorkspace() === self)
        provider = .codex; renderer = rendererKind; executable = executableURL; currentOwner = currentWorkspace
    }
}
@MainActor final class ControlledManager {
    var selectedWorkspace: Workspace?
    init(_ workspace: Workspace) { selectedWorkspace = workspace }
}

@MainActor final class AppDelegate: NSObject {
    var manager: ControlledManager?
    func activeTabManagerForCommands() -> ControlledManager? { manager }
    func openDebugAgentSessionReact(_ sender: Any?) { preconditionFailure("Ordinary GUI action must not run") }
    func openDebugAgentSessionSolid(_ sender: Any?) { preconditionFailure("Ordinary GUI action must not run") }
    func refuseUnsupportedNativeProvider() {
        openDebugManagedCoding(providerID: .opencode, rendererKind: .react)
    }
// __ACTUAL_MANAGED_ACTION_METHODS__
}

struct IrohTransportDebugMenuButtons: View { var body: some View { EmptyView() } }
struct NotificationDebugMenuButtons: View { var body: some View { EmptyView() } }

@main struct NativeActionFixture {
    @MainActor static func main() {
        let argument = CommandLine.arguments.last!
        let codex = argument.hasPrefix("codex-")
        let scenario = String(argument.dropFirst(codex ? 6 : 8))
        let provider: AgentSessionProviderID = codex ? .codex : .copilot
        let renderer: AgentSessionRendererKind = scenario == "solid" ? .solid : .react
        let workspace = Workspace()
        let manager = ControlledManager(workspace)
        let app = AppDelegate()
        app.manager = manager
        if scenario == "unsupported-native-provider" {
            for qualified in [ShepherdManagedProvider.copilot, .codex, .claude] {
                AgentSessionManagedNativeOwner.qualifiedProvider = qualified
                app.refuseUnsupportedNativeProvider()
                precondition(NSAlert.disclosures == 0 && NSAlert.errors == 0)
                precondition(Bundle.lookups == 0 && AgentExecutableResolver.resolutions == 0)
                precondition(workspace.provider == nil)
            }
            return
        }
        AgentSessionManagedNativeOwner.qualifiedProvider = codex ? .codex : .copilot
        AgentSessionManagedNativeOwner.qualifiedRenderer = renderer.rawValue
        if scenario == "unqualified" { AgentSessionManagedNativeOwner.qualifiedProvider = nil }
        if scenario == "foreign-provider" { AgentSessionManagedNativeOwner.qualifiedProvider = codex ? .copilot : .codex }
        if scenario == "foreign-renderer" { AgentSessionManagedNativeOwner.qualifiedRenderer = "solid" }
        if scenario == "cancel" { NSAlert.response = .alertSecondButtonReturn }
        if scenario == "helper-missing" { Bundle.missing = true }
        if scenario == "pane-missing" { workspace.bonsplitController.focusedPaneId = nil }
        if scenario == "manager-lost" { NSAlert.afterDisclosure = { app.manager = ControlledManager(workspace) } }
        if scenario == "workspace-lost" { NSAlert.afterDisclosure = { manager.selectedWorkspace = Workspace() } }
        if codex {
            if renderer == .solid { app.openDebugManagedCodexSolid(nil) }
            else { app.openDebugManagedCodexReact(nil) }
        } else {
            if renderer == .solid { app.openDebugManagedCopilotSolid(nil) }
            else { app.openDebugManagedCopilotReact(nil) }
        }
        if ["unqualified", "foreign-provider", "foreign-renderer"].contains(scenario) {
            precondition(NSAlert.disclosures == 0 && NSAlert.errors == 0)
            precondition(Bundle.lookups == 0 && AgentExecutableResolver.resolutions == 0)
            precondition(workspace.provider == nil)
            return
        }
        precondition(NSAlert.disclosures == 1, "CMUX_NATIVE_CODEX_ACTION_UNAVAILABLE: no explicit disclosure")
        precondition(NSAlert.disclosedTitle.contains(codex ? "Codex" : "Copilot"))
        if scenario == "cancel" {
            precondition(NSAlert.errors == 0 && workspace.provider == nil)
            precondition(Bundle.lookups == 0 && AgentExecutableResolver.resolutions == 0)
            return
        }
        if ["manager-lost", "workspace-lost", "pane-missing"].contains(scenario) {
            precondition(NSAlert.errors == 1 && workspace.provider == nil)
            precondition(Bundle.lookups == 0 && AgentExecutableResolver.resolutions == 0)
            return
        }
        precondition(Bundle.lookups == (codex ? 1 : 0))
        precondition(AgentExecutableResolver.resolutions == (codex ? 0 : 1))
        precondition(AgentExecutableResolver.configurations == (codex ? 0 : 1))
        if scenario == "helper-missing" {
            precondition(NSAlert.errors == 1 && workspace.provider == nil)
            return
        }
        precondition(NSAlert.errors == 0)
        precondition(workspace.provider == provider && workspace.renderer == renderer,
                     "CMUX_NATIVE_CODEX_ACTION_UNAVAILABLE: wrong provider or renderer")
        precondition(workspace.executable?.path == (codex
                     ? "/controlled/bundle/bin/cmux-managed-codex-host" : "/controlled/copilot"))
        precondition(workspace.currentOwner?() === workspace)
        if scenario == "owner-getter" {
            manager.selectedWorkspace = Workspace()
            precondition(workspace.currentOwner?() === manager.selectedWorkspace)
            app.manager = nil
            precondition(workspace.currentOwner?() == nil)
        }
    }
}
