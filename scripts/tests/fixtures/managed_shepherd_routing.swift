import CmuxControlSocket
import Foundation

enum WorkspaceRemoteRelayCommandRewriter {
    static let remoteWorkspaceIDKey = "_cmux_remote_workspace_id"
}

// This fixture cuts off exactly at the remote authorizer; all native dispatch
// prefixes and local discovery bodies below are copied from production.
struct DiffViewerSessionPreparation { static let notNeeded = Self() }
enum V2MainHopOutcome { case callResult(ControlCallResult) }

@MainActor final class RoutingClassicBoundary {
    nonisolated func handle(_ request: ControlRequest, peer: ShepherdControlPeer?) async -> ControlCallResult {
        .err(code: "classic_boundary", message: "", data: nil)
    }
    func handleSynchronously(_ request: ControlRequest, peer: ShepherdControlPeer?) -> ControlCallResult {
        .err(code: "access_denied", message: "", data: nil)
    }
}

struct RoutingEncoder {
    func response(id: JSONValue?, _ result: ControlCallResult) -> String {
        if case .err(let code, _, _) = result { return code }
        return "ok"
    }
}

@MainActor final class TerminalController {
    nonisolated static let v2Encoder = RoutingEncoder()
    var managedLookups = 0
    var classicLookups = 0
    private lazy var managed = makeManagedShepherdControlBoundary()
    private let classic = RoutingClassicBoundary()
    var managedShepherdControlBoundary: AgentSessionManagedShepherdBoundary {
        managedLookups += 1
        return managed
    }
    var shepherdControlBoundary: RoutingClassicBoundary {
        classicLookups += 1
        return classic
    }

    nonisolated func withSocketCommandPolicyAsync(
        commandKey: String, isV2: Bool, params: [String: JSONValue],
        operation: () async -> String
    ) async -> String { await operation() }

    nonisolated func v2Capabilities() -> [String: Any] {
        ["methods": ["system.ping", "surface.shepherd.managed.inspect"]]
    }

    // __SHEPHERD_ROUTE__
    // __SOCKET_ROUTE__
    // __CAPABILITIES__
    // __SYNC_ROUTE__
    // __MANAGED_FACTORY__

    func route(_ request: ControlRequest, _ peer: ShepherdControlPeer?) async throws -> String {
        try await processV2CommandUsingSocketExecutionPolicyAsync(request, shepherdPeer: peer) ?? "nil"
    }
}

enum AgentSessionRendererKind: String { case react, solid }

@MainActor final class AgentSessionWebRendererCoordinator {
    let processStore: AgentSessionProcessStore
    var nativeCodingOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var managedRendererOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var managedRendererController: AgentSessionManagedRendererController?
    var isClosed = false
    var panelId: UUID
    var workspaceId: UUID
    var rendererKind = AgentSessionRendererKind.react
    var workingDirectory: String?
    var contextAvailable = true
    let context: () -> AgentSessionManagedRendererController.Context?

    init(store: AgentSessionProcessStore, owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner,
         renderer: AgentSessionManagedRendererController,
         context: @escaping () -> AgentSessionManagedRendererController.Context?) {
        processStore = store
        nativeCodingOwner = owner
        managedRendererOwner = owner
        managedRendererController = renderer
        panelId = owner.scope.surfaceID
        workspaceId = owner.scope.workspaceID
        workingDirectory = owner.workingDirectory
        self.context = context
    }

    // __MANAGED_RENDERER__
    // __COORDINATOR_TARGET__

    private func installManagedRendererObservation() {}
    private func currentManagedRendererContext(
        for owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner
    ) -> AgentSessionManagedRendererController.Context? { contextAvailable ? context() : nil }
    private func performManagedRendererOperation(
        _ operation: AgentSessionManagedRendererController.Operation
    ) async throws -> Any? { throw POSIXError(.ENOTSUP) }
}

@MainActor final class AgentSessionWebRendererSession {
    let ownedCoordinator: AgentSessionWebRendererCoordinator
    init(_ coordinator: AgentSessionWebRendererCoordinator) { ownedCoordinator = coordinator }
    // __SESSION_TARGET__
}

@MainActor final class AgentSessionPanel {
    var id: UUID
    var workspaceId: UUID
    var isClosed = false
    let rendererSession: AgentSessionWebRendererSession
    init(_ session: AgentSessionWebRendererSession, owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner) {
        rendererSession = session
        id = owner.scope.surfaceID
        workspaceId = owner.scope.workspaceID
    }
}

@MainActor final class RoutingWorkspace {
    var id: UUID
    var isRemoteWorkspace = false
    var panels: [UUID: AnyObject] = [:]
    init(_ id: UUID) { self.id = id }
}

@MainActor final class AppDelegate {
    struct Located { let workspace: RoutingWorkspace }
    static var shared: AppDelegate?
    var workspace: RoutingWorkspace
    init(_ workspace: RoutingWorkspace) { self.workspace = workspace }
    func workspaceContainingPanel(panelId: UUID, preferredWorkspaceId: UUID) -> Located? {
        Located(workspace: workspace)
    }
}

@MainActor enum ManagedShepherdRoutingFixture {
    static func run(_ scenario: String) async throws -> [String: Any] {
        let controller = TerminalController()
        let methods = [
            "surface.shepherd.managed.inspect", "surface.shepherd.managed.continue",
            "surface.shepherd.managed.receipt",
        ]
        let local = ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
        switch scenario {
        case "managed-socket-route":
            let commands = methods + ["surface.shepherd.inspect", "surface.shepherd.managed.paste", "system.ping"]
            let recognized = commands.map { method in
                TerminalController.isShepherdSocketCommand("{\"id\":1,\"method\":\"\(method)\",\"params\":{}}")
            }

            var results: [String] = []
            for method in methods {
                results.append(try await controller.route(.init(id: nil, method: method, params: [:]), local))
            }
            return [
                "recognized": recognized, "managed": results,
                "classic": try await controller.route(
                    .init(id: nil, method: "surface.shepherd.inspect", params: [:]), local),
                "other": try await controller.route(.init(id: nil, method: "system.ping", params: [:]), local),
            ]
        case "managed-socket-provenance":
            var errors: [String] = []
            for method in methods {
                let request = ControlRequest(id: nil, method: method, params: [:])
                for peer: ShepherdControlPeer? in [
                    nil, .init(peerHasSameUID: false, isRemoteRelay: false),
                    .init(peerHasSameUID: true, isRemoteRelay: true),
                ] {
                    errors.append(try await controller.route(request, peer))
                }
                errors.append(try await controller.route(.init(id: nil, method: method, params: [
                    "_cmux_remote_workspace_id": .null,
                ]), local))
            }
            return ["errors": errors, "managedLookups": controller.managedLookups,
                    "classicLookups": controller.classicLookups]
        case "managed-socket-capabilities":
            let local = controller.v2CapabilitiesWithBrowserDesignMode(params: [:])
            let remote = controller.v2CapabilitiesWithBrowserDesignMode(
                params: ["_cmux_remote_workspace_id": UUID().uuidString]
            )
            let classic = local["shepherd_guarded_input"] as? [String: Any] ?? [:]
            return [
                "localManagedMethods": methods.allSatisfy { (local["methods"] as? [String] ?? []).contains($0) },
                "managed": local["shepherd_managed_input"] as? [String: Any] ?? [:],
                "remoteManagedMethods": (remote["methods"] as? [String] ?? []).contains {
                    $0.hasPrefix("surface.shepherd.managed.")
                },
                "remoteManagedCapability": remote["shepherd_managed_input"] != nil,
                "classicState": classic["state"] ?? "", "classicReason": classic["qualification_reason"] ?? "",
            ]
        case "managed-socket-sync":
            let errors = methods.map { method -> String in
                let request = ControlRequest(id: nil, method: method, params: [:])
                let result = controller.v2MainActorResponse(request: request, id: nil, method: method, params: [:])
                if case .callResult(.err(let code, _, _)) = result { return code }
                return "unexpected"
            }
            return ["errors": errors, "managedLookups": controller.managedLookups]
        default: throw POSIXError(.EINVAL)
        }
    }
}
