import CmuxControlSocket
import Foundation

@MainActor
enum ManagedShepherdBoundaryFixture {
    static func payload(_ result: ControlCallResult) -> [String: Any] {
        switch result {
        case .ok(.object(let value)): return value.mapValues(\.foundationObject)
        case .err(let code, _, _): return ["error": code]
        default: return ["error": "unexpected_result"]
        }
    }

    static func run(
        _ scenario: String, store: AgentSessionProcessStore,
        nativeOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner,
        sessionID: String, directory: URL
    ) async throws -> [String: Any] {
        let local = ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
        let inputID = UUID()
        let host = NSObject()
        let hostIdentity = ObjectIdentifier(host)
        var editor = ""
        var captures = 0
        var insertions = 0
        var consumes = 0
        var registeredBeforeInsertion = false
        var requestTask: Task<ControlCallResult, Never>?
        var boundary: AgentSessionManagedShepherdBoundary!
        let context: () -> AgentSessionManagedRendererController.Context? = {
                guard store.ownsManagedCodingOwner(nativeOwner) else { return nil }
                return .init(
                    owner: ObjectIdentifier(nativeOwner), store: ObjectIdentifier(store),
                    coordinator: hostIdentity, host: hostIdentity, webView: hostIdentity,
                    window: hostIdentity, responder: hostIdentity, workspaceID: nativeOwner.scope.workspaceID,
                    panelID: nativeOwner.scope.surfaceID, renderer: "react",
                    document: "file:///controlled/managed-rpc.html",
                    paintGeneration: 1, geometry: [0, 0, 800, 600]
                )
        }
        let controller = AgentSessionManagedRendererController(
            context: context,
            operation: { operation in
                switch operation {
                case .capture:
                    captures += 1
                    return ["editorText": editor, "editVersion": "edit-\(insertions)",
                            "render": "paint-\(insertions)", "screen": "Paint-bound native output"]
                case .reserve(_, let text):
                    let prior = payload(await boundary.handle(
                        ControlRequest(id: nil, method: "surface.shepherd.managed.receipt",
                                       params: ["request_id": .string(inputID.uuidString)]), peer: local
                    ))
                    registeredBeforeInsertion = prior["state"] as? String == "unknown" &&
                        prior["request_id"] as? String == inputID.uuidString
                    insertions += 1
                    editor = text
                    if scenario.hasSuffix("-cancel") { requestTask?.cancel() }
                    if scenario.hasSuffix("-nil-insert") { return nil }
                    if scenario.hasSuffix("-throw-insert") { throw POSIXError(.EIO) }
                    return ["leaseId": "lease-1", "render": "paint-1"]
                case .validate: return true
                case .release: return nil
                case .consume:
                    guard editor == "Continue authorized coding." else { return false }
                    consumes += 1
                    editor = ""
                    return true
                }
            }, onReleaseError: { error in fatalError("unexpected controlled release error: \(error)") }
        )
        if scenario.hasSuffix("-target-accessor") || scenario.hasSuffix("-target-factory") {
            let coordinator = AgentSessionWebRendererCoordinator(
                store: store, owner: nativeOwner, renderer: controller, context: context
            )
            let session = AgentSessionWebRendererSession(coordinator)
            if scenario.hasSuffix("-target-factory") {
                let panel = AgentSessionPanel(session, owner: nativeOwner)
                let workspace = RoutingWorkspace(nativeOwner.scope.workspaceID)
                workspace.panels[panel.id] = panel
                AppDelegate.shared = AppDelegate(workspace)
                var socketOwner: TerminalController? = TerminalController()
                let factoryBoundary = socketOwner!.makeManagedShepherdControlBoundary()
                let request = ControlRequest(id: nil, method: "surface.shepherd.managed.inspect", params: [
                    "workspace_id": .string(nativeOwner.scope.workspaceID.uuidString),
                    "surface_id": .string(nativeOwner.scope.surfaceID.uuidString),
                ])
                let inspection = payload(await factoryBoundary.handle(request, peer: local))
                var refused: [String] = []
                func reject() async {
                    refused.append(payload(await factoryBoundary.handle(request, peer: local))["error"] as? String ?? "")
                }
                workspace.id = UUID()
                await reject()
                workspace.id = nativeOwner.scope.workspaceID
                workspace.isRemoteWorkspace = true
                await reject()
                workspace.isRemoteWorkspace = false
                workspace.panels[panel.id] = NSObject()
                await reject()
                workspace.panels[panel.id] = panel
                panel.workspaceId = UUID()
                await reject()
                panel.workspaceId = workspace.id
                panel.id = UUID()
                await reject()
                panel.id = nativeOwner.scope.surfaceID
                panel.isClosed = true
                await reject()
                panel.isClosed = false
                coordinator.contextAvailable = false
                await reject()
                coordinator.contextAvailable = true
                socketOwner = nil
                await reject()
                AppDelegate.shared = nil
                store.closeAll()
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while store.hasActiveProviderSession, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                return [
                    "inspectedExactTarget": inspection["screen"] as? String == "Paint-bound native output",
                    "refused": refused, "captures": captures, "insertions": insertions,
                    "stopped": !store.hasActiveProviderSession,
                ]
            }
            let target = session.managedShepherdTarget()
            let exact = target?.nativeOwner === nativeOwner && target?.store === store &&
                target?.renderer === controller && target?.sessionID == sessionID
            var refused: [Bool] = []
            coordinator.nativeCodingOwner = nil
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.nativeCodingOwner = nativeOwner
            coordinator.isClosed = true
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.isClosed = false
            coordinator.panelId = UUID()
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.panelId = nativeOwner.scope.surfaceID
            coordinator.workspaceId = UUID()
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.workspaceId = nativeOwner.scope.workspaceID
            coordinator.rendererKind = .solid
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.rendererKind = .react
            coordinator.workingDirectory = "/foreign/project"
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.workingDirectory = nativeOwner.workingDirectory
            coordinator.contextAvailable = false
            refused.append(session.managedShepherdTarget() == nil)
            coordinator.contextAvailable = true
            let foreignStore = AgentSessionProcessStore()
            refused.append(foreignStore.managedCodingSessionID(for: nativeOwner) == nil)
            store.closeAll()
            refused.append(session.managedShepherdTarget() == nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while store.hasActiveProviderSession, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return ["exactTarget": exact, "refused": refused, "captures": captures,
                    "insertions": insertions, "stopped": !store.hasActiveProviderSession]
        }
        boundary = AgentSessionManagedShepherdBoundary { workspace, surface in
            guard workspace == nativeOwner.scope.workspaceID, surface == nativeOwner.scope.surfaceID else {
                return nil
            }
            return .init(nativeOwner: nativeOwner, store: store, renderer: controller, sessionID: sessionID)
        }
        let inspect = ControlRequest(id: nil, method: "surface.shepherd.managed.inspect", params: [
            "workspace_id": .string(nativeOwner.scope.workspaceID.uuidString),
            "surface_id": .string(nativeOwner.scope.surfaceID.uuidString),
        ])
        var rejected: [String] = []
        if scenario.hasSuffix("-provenance") {
            for peer: ShepherdControlPeer? in [
                nil, .init(peerHasSameUID: false, isRemoteRelay: false),
                .init(peerHasSameUID: true, isRemoteRelay: true),
            ] {
                rejected.append(payload(await boundary.handle(inspect, peer: peer))["error"] as? String ?? "")
            }
            var params = inspect.params
            params["_cmux_remote_workspace_id"] = .string(UUID().uuidString)
            rejected.append(payload(await boundary.handle(
                ControlRequest(id: nil, method: inspect.method, params: params), peer: local
            ))["error"] as? String ?? "")
        } else if scenario.hasSuffix("-parameters") {
            for request in [
                ControlRequest(id: nil, method: inspect.method, params: [:]),
                ControlRequest(id: nil, method: inspect.method, params: [
                    "workspace_id": .string("workspace:1"),
                    "surface_id": .string(nativeOwner.scope.surfaceID.uuidString),
                ]),
                ControlRequest(id: nil, method: "surface.shepherd.managed.receipt", params: [
                    "request_id": .string(inputID.uuidString), "text": .string("caller claim"),
                ]),
                ControlRequest(id: nil, method: "surface.shepherd.continue", params: [:]),
                ControlRequest(id: nil, method: "surface.shepherd.managed.continue", params: [
                    "request_id": .string(inputID.uuidString), "token": .string(UUID().uuidString),
                    "text": .string("Continue."), "approved": .bool(true),
                ]),
            ] {
                rejected.append(payload(await boundary.handle(request, peer: local))["error"] as? String ?? "")
            }
        }
        var inspection: [String: Any] = [:]
        var first: [String: Any] = [:]
        var replay: [String: Any] = [:]
        var conflict: [String: Any] = [:]
        var final: [String: Any] = [:]
        if rejected.isEmpty {
            inspection = payload(await boundary.handle(inspect, peer: local))
            guard let token = inspection["token"] as? [String: Any], let tokenID = token["id"] as? String else {
                throw POSIXError(.EPROTO)
            }
            let request = ControlRequest(id: nil, method: "surface.shepherd.managed.continue", params: [
                "request_id": .string(inputID.uuidString), "token": .string(tokenID),
                "text": .string("Continue authorized coding."),
            ])
            requestTask = Task { await boundary.handle(request, peer: local) }
            first = payload(await requestTask!.value)
            replay = payload(await boundary.handle(request, peer: local))
            var different = request.params
            different["text"] = .string("Different text.")
            conflict = payload(await boundary.handle(
                ControlRequest(id: nil, method: request.method, params: different), peer: local
            ))
            if scenario.hasSuffix("-late-ack") || scenario.hasSuffix("-missing-ack") {
                let until = ContinuousClock.now.advanced(by: .seconds(6))
                while ContinuousClock.now < until {
                    final = payload(await boundary.handle(
                        ControlRequest(id: nil, method: "surface.shepherd.managed.receipt",
                                       params: ["request_id": .string(inputID.uuidString)]), peer: local
                    ))
                    if final["state"] as? String == "accepted" || !store.hasActiveProviderSession { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let cleanupDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
            while consumes == 0, first["state"] as? String == "accepted",
                  ContinuousClock.now < cleanupDeadline { await Task.yield() }
        }
        store.closeAll()
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        while store.hasActiveProviderSession, ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if rejected.isEmpty {
            final = payload(await boundary.handle(
                ControlRequest(id: nil, method: "surface.shepherd.managed.receipt",
                               params: ["request_id": .string(inputID.uuidString)]), peer: local
            ))
        }
        let trace = try String(
            contentsOf: directory.appendingPathComponent(".cmux-controlled-copilot-trace"), encoding: .utf8
        )
        return [
            "inspection": inspection, "first": first, "replay": replay, "conflict": conflict, "final": final,
            "rejected": rejected, "captures": captures, "insertions": insertions, "consumes": consumes,
            "editor": editor, "registeredBeforeInsertion": registeredBeforeInsertion,
            "sendCount": trace.split(separator: "\n").filter { $0 == "session.send" }.count,
            "storeProgressAfterClose": store.managedSupervisorInputProgress(
                sessionId: sessionID, inputID: inputID
            ) != nil,
            "identityHost": nativeOwner.scope.hostInstance.uuidString,
            "directory": directory.resolvingSymlinksInPath().path,
            "stopped": !store.hasActiveProviderSession,
        ]
    }
}
