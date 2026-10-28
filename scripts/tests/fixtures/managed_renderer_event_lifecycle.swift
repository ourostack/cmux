import Foundation

@MainActor final class ControlledEventStore {
    var eventSink: (([String: Any]) -> Void)?
}

@MainActor final class ControlledTurnNotifier {
    func observe(_ event: [String: Any]) {}
}

@MainActor final class ControlledEventWebView {
    func evaluateJavaScript(_ script: String, completionHandler: (Any?, Error?) -> Void) {
        completionHandler(nil, nil)
    }
}

@MainActor final class ControlledEventCoordinator {
    let processStore = ControlledEventStore()
    var managedRendererController: AgentSessionManagedRendererController?
    var turnNotifier: ControlledTurnNotifier? = ControlledTurnNotifier()
    var webView: ControlledEventWebView? = ControlledEventWebView()

    func bindEventSink() {
        // __EVENT_SINK__
    }

    func emitDirect(_ event: [String: Any]) {
        sendEvent(event)
    }

    // __SEND_EVENT__
}

@main
struct ManagedRendererEventLifecycleFixture {
    enum Failure: Error { case assertion(String) }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func main() async {
        do {
            guard let scenario = CommandLine.arguments.dropFirst().first,
                  ["store", "direct"].contains(scenario) else { throw Failure.assertion("unknown scenario") }
            let coordinator = ControlledEventCoordinator()
            let identity = ObjectIdentifier(coordinator)
            let context = AgentSessionManagedRendererController.Context(
                owner: identity, store: identity, coordinator: identity, host: identity, webView: identity,
                window: identity, responder: identity, workspaceID: UUID(), panelID: UUID(), renderer: "react",
                document: "file:///controlled/event-host.html", paintGeneration: 1, geometry: [0, 0, 800, 600]
            )
            var now = ContinuousClock.now
            var consumeCalls = 0
            let controller = AgentSessionManagedRendererController(
                context: { context },
                operation: { operation in
                    switch operation {
                    case .capture:
                        return ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                                "screen": "Visible output"]
                    case .reserve: return ["leaseId": "lease-1", "render": "paint-2"]
                    case .validate: return true
                    case .release: return nil
                    case .consume(let receipt):
                        try check(receipt == ["leaseId": "lease-1", "render": "paint-2"],
                                  "native event changed owned cleanup identity")
                        consumeCalls += 1
                        return true
                    }
                }, now: { now }, sleep: { now = now.advanced(by: $0) },
                onReleaseError: { error in fatalError("unexpected controlled release failure: \(error)") }
            )
            coordinator.managedRendererController = controller
            coordinator.bindEventSink()
            guard let snapshot = try await controller.capture(),
                  let insertion = try await controller.insert(snapshot, text: "Owned literal"),
                  let frame = try await controller.prepareFrame(insertion) else {
                throw Failure.assertion("missing native insertion frame")
            }
            try check(frame.validate(), "native frame was not initially current")
            let event: [String: Any] = ["type": "provider.output", "text": "New coding output"]
            if scenario == "store" {
                coordinator.processStore.eventSink?(event)
            } else {
                coordinator.emitDirect(event)
            }
            try check(!frame.validate(), "native output retained backend write authority")
            now = now.advanced(by: .seconds(3))
            let consumed = try await controller.consume(insertion)
            try check(consumed && consumeCalls == 1, "native output discarded exact owned editor cleanup")
            try check(!frame.validate(), "cleanup revived backend write authority")
            print("passed")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
