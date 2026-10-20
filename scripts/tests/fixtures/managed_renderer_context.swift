// Only native properties are controlled: no AppKit, WebKit, provider, or input delivery.
import Foundation
import CoreGraphics

@MainActor class NSResponder: NSObject {
    var nextResponder: NSResponder?
}

@MainActor class NSWindow: NSObject {
    struct Occlusion: OptionSet {
        let rawValue: Int
        static let visible = Self(rawValue: 1)
    }
    var firstResponder: NSResponder? = NSResponder()
    var isKeyWindow = true
    var isVisible = true
    var isMiniaturized = false
    var occlusionState: Occlusion = .visible
    var frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    var contentLayoutRect = CGRect(x: 0, y: 20, width: 800, height: 580)
    var backingScaleFactor: CGFloat = 2
}

@MainActor class NSView: NSResponder {
    var window: NSWindow?
    var superview: NSView?
    var isHiddenOrHasHiddenAncestor = false
    var isHidden = false
    var alphaValue: CGFloat = 1
    var frame = CGRect(x: 0, y: 0, width: 400, height: 500)
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
    var visibleRect = CGRect(x: 0, y: 0, width: 400, height: 500)
    func convert(_ rect: CGRect, to: NSView?) -> CGRect { rect }
}

@MainActor final class WebView: NSView {
    var isLoading = false
    var url: URL? = URL(fileURLWithPath: "/controlled/agent-session.html")
}

@MainActor final class Application {
    var isActive = true
}
@MainActor let NSApp = Application()

enum AgentSessionManagedCopilotLaunch {
    @MainActor final class NativeCodingOwner {
        struct Scope {
            var surfaceID = UUID()
            var workspaceID = UUID()
        }
        var scope = Scope()
        var rendererID = "react"
        var workingDirectory = "/controlled/project"
    }
}

@MainActor final class Store {
    var owned: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    func ownsManagedCodingOwner(_ owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner) -> Bool {
        owned === owner
    }
}

@MainActor final class Coordinator {
    let processStore = Store()
    var managedRendererOwner: AgentSessionManagedCopilotLaunch.NativeCodingOwner?
    var isClosed = false
    var isPanelFocused = false
    var hasFinishedNavigation = true
    var hasCompletedVisiblePaintFlush = true
    var panelId = UUID()
    var workspaceId = UUID()
    enum Renderer: String { case react, solid }
    var rendererKind = Renderer.react
    var workingDirectory: String? = "/controlled/project"
    var attachedHost: NSView? = NSView()
    var webView: WebView? = WebView()
    var trustedShellURL: URL? = URL(fileURLWithPath: "/controlled/agent-session.html")
    var visiblePaintGeneration: UInt64 = 1

    init(_ owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner) {
        processStore.owned = owner
        managedRendererOwner = owner
        panelId = owner.scope.surfaceID
        workspaceId = owner.scope.workspaceID
        let window = NSWindow()
        attachedHost?.window = window
        webView?.window = window
        webView?.superview = attachedHost
    }

    func context(_ owner: AgentSessionManagedCopilotLaunch.NativeCodingOwner)
        -> AgentSessionManagedRendererController.Context? {
        currentManagedRendererContext(for: owner)
    }

    // __CONTEXT_METHOD__
    // __TRUST_METHODS__
    // __RESPONDER_METHOD__
}

@main struct ManagedRendererContextFixture {
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    @MainActor static func main() async {
        do {
            try await run(CommandLine.arguments[1])
            print("passed")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ scenario: String) async throws {
        let owner = AgentSessionManagedCopilotLaunch.NativeCodingOwner()
        let coordinator = Coordinator(owner)
        let host = coordinator.attachedHost!
        let view = coordinator.webView!
        let window = view.window!
        let otherResponder = window.firstResponder
        switch scenario {
        case "panel-focused": coordinator.isPanelFocused = true; window.firstResponder = view
        case "web-focused": window.firstResponder = view
        case "web-descendant-focused":
            let responder = NSResponder()
            responder.nextResponder = view
            window.firstResponder = responder
        case "no-responder": window.firstResponder = nil
        case "not-owned": coordinator.processStore.owned = nil
        case "foreign-owner": coordinator.managedRendererOwner = .init()
        case "closed": coordinator.isClosed = true
        case "navigation": coordinator.hasFinishedNavigation = false
        case "paint": coordinator.hasCompletedVisiblePaintFlush = false
        case "panel": owner.scope.surfaceID = UUID()
        case "workspace": owner.scope.workspaceID = UUID()
        case "renderer": owner.rendererID = "solid"
        case "directory": owner.workingDirectory = "/other"
        case "no-host": coordinator.attachedHost = nil
        case "no-webview": coordinator.webView = nil
        case "no-window": view.window = nil
        case "foreign-window": host.window = NSWindow()
        case "foreign-parent": view.superview = NSView()
        case "inactive": NSApp.isActive = false
        case "not-key": window.isKeyWindow = false
        case "invisible": window.isVisible = false
        case "miniaturized": window.isMiniaturized = true
        case "occluded": window.occlusionState = []
        case "hidden-host-ancestor": host.isHiddenOrHasHiddenAncestor = true
        case "hidden-view-ancestor": view.isHiddenOrHasHiddenAncestor = true
        case "empty-host": host.visibleRect = .zero
        case "empty-view": view.visibleRect = .zero
        case "loading": view.isLoading = true
        case "untrusted-url": view.url = URL(string: "https://untrusted.invalid/")
        case "missing-trust": coordinator.trustedShellURL = nil
        case "ancestor-opacity":
            let ancestor = NSView(); ancestor.alphaValue = 0; host.superview = ancestor
        case "ancestor-hidden":
            let ancestor = NSView(); ancestor.isHidden = true; host.superview = ancestor
        case "nonfinite": window.backingScaleFactor = .infinity
        case "unfocused", "responder-changed", "geometry-changed": break
        default: throw Failure.assertion("unknown scenario")
        }
        let positive = ["unfocused", "responder-changed", "geometry-changed"].contains(scenario)
        if !positive {
            try check(coordinator.context(owner) == nil, "unsafe native context admitted: \(scenario)")
            return
        }
        var now = ContinuousClock.now
        var rendererCalls = 0
        let controller = AgentSessionManagedRendererController(
            context: { coordinator.context(owner) },
            operation: { operation in
                rendererCalls += 1
                switch operation {
                case .capture: return ["editorText": "", "editVersion": "edit-1", "render": "render-1",
                                       "screen": "Visible output"]
                case .reserve: return ["leaseId": "lease-1", "render": "render-2"]
                case .validate: return true
                case .release: return nil
                }
            }, now: { now }, sleep: { now = now.advanced(by: $0) },
            onReleaseError: { error in fatalError("unexpected renderer release: \(error)") }
        )
        guard let capture = try await controller.capture(),
              let insertion = try await controller.insert(capture, text: "controlled literal"),
              let frame = try await controller.prepareFrame(insertion) else {
            throw Failure.assertion("visible unfocused native target did not produce evidence")
        }
        try check(rendererCalls == 3 && frame.validate(), "unfocused evidence was not current")
        try check(window.firstResponder === otherResponder && !coordinator.isPanelFocused,
                  "unfocused capture stole human focus")
        if scenario == "responder-changed" { window.firstResponder = NSResponder() }
        if scenario == "geometry-changed" { window.frame.origin.x += 1 }
        if scenario != "unfocused" {
            try check(!frame.validate(), "changed native context retained an admissible frame")
        }
    }
}
