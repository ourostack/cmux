// AppKit/WebKit stand-ins isolate our actual view mutation bodies without starting a GUI or event monitor.
#if MOCK_APPKIT
@_exported import CoreGraphics
@_exported import Foundation

@MainActor open class NSWindow: NSObject {
    public let windowNumber = 1
    public func makeFirstResponder(_ responder: NSObject?) -> Bool { true }
    public static let didBecomeKeyNotification = Notification.Name("mock.window.key")
    public static let didResignKeyNotification = Notification.Name("mock.window.resign")
    public static let willMoveNotification = Notification.Name("mock.window.willMove")
    public static let didMoveNotification = Notification.Name("mock.window.move")
    public static let didResizeNotification = Notification.Name("mock.window.resize")
    public static let didChangeOcclusionStateNotification = Notification.Name("mock.window.occlusion")
    public static let willCloseNotification = Notification.Name("mock.window.close")
    public static let didMiniaturizeNotification = Notification.Name("mock.window.miniaturize")
    public static let didDeminiaturizeNotification = Notification.Name("mock.window.deminiaturize")
}

@MainActor public enum NSApplication {
    public static let willResignActiveNotification = Notification.Name("mock.application.resign")
    public static let didChangeScreenParametersNotification = Notification.Name("mock.application.screen")
}

@MainActor open class NSEvent: NSObject {
    public enum EventTypeMask { case any }
    public let scrollingDeltaX: CGFloat = 0
    public let scrollingDeltaY: CGFloat = 1
    public let hasPreciseScrollingDeltas = true
    public var cmuxIsUndoRedoCommandEquivalent: Bool { false }
    public static func addLocalMonitorForEvents(
        matching: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? { NSObject() }
    nonisolated public static func removeMonitor(_ monitor: Any) {}
}

@MainActor open class NSView: NSObject {
    public enum Ordering { case above }
    public var frame = CGRect.zero
    public var bounds = CGRect.zero
    public var window: NSWindow?
    public private(set) weak var superview: NSView?
    private var children: [NSView] = []
    public var translatesAutoresizingMaskIntoConstraints = true
    public var autoresizingMask: [Int] = []
    public var needsLayout = false
    open var alphaValue: CGFloat = 1
    open var isHidden = false
    open var isOpaque: Bool { false }
    open func viewWillMove(toWindow newWindow: NSWindow?) {}
    open func viewWillMove(toSuperview newSuperview: NSView?) {}
    open func viewDidMoveToWindow() {}
    open func viewDidMoveToSuperview() {}
    open func layout() {}
    public func layoutSubtreeIfNeeded() { layout() }
    open func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    open func mouseDown(with event: NSEvent) {}
    open func scrollWheel(with event: NSEvent) {}
    open func becomeFirstResponder() -> Bool { true }
    open func resignFirstResponder() -> Bool { true }
    open func setFrameOrigin(_ point: NSPoint) { frame.origin = point }
    open func setFrameSize(_ size: NSSize) { frame.size = size }
    open func setBoundsOrigin(_ point: NSPoint) { bounds.origin = point }
    open func setBoundsSize(_ size: NSSize) { bounds.size = size }
    public func removeFromSuperview() {
        viewWillMove(toSuperview: nil)
        superview?.children.removeAll { $0 === self }
        superview = nil
        viewDidMoveToSuperview()
    }
    public func addSubview(_ view: NSView, positioned: Ordering, relativeTo: NSView?) {
        view.viewWillMove(toSuperview: self)
        children.append(view)
        view.superview = self
        view.viewDidMoveToSuperview()
    }
}
#elseif MOCK_WEBKIT
@_exported import AppKit

@MainActor open class WKWebView: NSView {
    public var onEvaluate: ((String) -> Void)?
    public func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        onEvaluate?(script)
        completionHandler?(nil, nil)
    }
}
#elseif MOCK_BROWSER
@_exported import WebKit

@MainActor open class CmuxUndoableWebView: WKWebView {
    open func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool { false }
}
#else
import AppKit
import Foundation
import WebKit

enum PaneFirstClickFocusSettings {
    static func isEnabled() -> Bool { false }
}

struct SessionContentWidthPresentation: Equatable {
    static let disabled = Self()
    func contentFrame(in bounds: CGRect) -> CGRect { bounds }
}

@main
struct ManagedRendererNativeBoundaryFixture {
    enum Failure: Error { case assertion(String) }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure.assertion("missing scenario") }
            try await run(CommandLine.arguments[1])
            print("passed")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ scenario: String) async throws {
        let host = AgentSessionWebHostView()
        let webView = AgentSessionWebView()
        host.attachWebView(webView)
        let owner = NSObject()
        let context = AgentSessionManagedRendererController.Context(
            owner: ObjectIdentifier(owner), store: ObjectIdentifier(owner), coordinator: ObjectIdentifier(owner),
            host: ObjectIdentifier(host), webView: ObjectIdentifier(webView), window: ObjectIdentifier(owner),
            responder: ObjectIdentifier(webView), workspaceID: UUID(), panelID: UUID(), renderer: "react",
            document: "file:///controlled/mock-host.html", paintGeneration: 1, geometry: [0, 0, 800, 600]
        )
        var now = ContinuousClock.now
        let controller = AgentSessionManagedRendererController(
            context: { context },
            operation: { operation in
                switch operation {
                case .capture: return ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                                       "screen": "Visible output"]
                case .reserve: return ["leaseId": "lease-1", "render": "paint-2"]
                case .validate: return true
                case .release: return nil
                case .consume: return true
                }
            }, now: { now }, sleep: { now = now.advanced(by: $0) },
            onReleaseError: { error in fatalError("unexpected release failure: \(error)") }
        )
        host.onManagedRendererInvalidation = { controller.invalidate() }
        webView.observeManagedRendererChanges { controller.invalidate() }
        defer { webView.observeManagedRendererChanges(nil) }
        if scenario == "deferred-scroll" { host.scrollWheel(with: NSEvent()) }
        guard let snapshot = try await controller.capture(),
              let insertion = try await controller.insert(snapshot, text: "controlled literal"),
              let frame = try await controller.prepareFrame(insertion) else {
            throw Failure.assertion("missing controlled native frame")
        }
        try check(frame.validate(), "frame was not current before the tested mutation")
        if scenario == "deferred-scroll" {
            var admittedAtForward: Bool?
            webView.onEvaluate = { _ in admittedAtForward = frame.validate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while admittedAtForward == nil {
                try check(ContinuousClock.now < deadline, "deferred scroll never forwarded")
                await Task.yield()
            }
            try check(admittedAtForward == false, "deferred scroll forwarded while fresh frame remained admissible")
        } else {
            let view: NSView = scenario.hasPrefix("host-") ? host : webView
            if scenario.hasSuffix("-opacity") {
                view.alphaValue = 0
                view.alphaValue = 1
            } else {
                view.isHidden = true
                view.isHidden = false
            }
            try check(!frame.validate(), "owned view visibility ABA revived the old native frame")
        }
    }
}
#endif
