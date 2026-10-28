import AppKit
import CmuxBrowser
import WebKit

@MainActor
final class AgentSessionWebView: CmuxUndoableWebView {
    var onPointerDown: (() -> Void)?
    private var onManagedRendererInvalidation: (() -> Void)?
    private var managedEventMonitor: Any?
    private var managedNotificationObservers: [NSObjectProtocol] = []

    func observeManagedRendererChanges(_ invalidate: (() -> Void)?) {
        onManagedRendererInvalidation?()
        onManagedRendererInvalidation = invalidate
        if let managedEventMonitor { NSEvent.removeMonitor(managedEventMonitor) }
        managedEventMonitor = nil
        managedNotificationObservers.forEach(NotificationCenter.default.removeObserver)
        managedNotificationObservers = []
        guard invalidate != nil else { return }
        managedEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
            MainActor.assumeIsolated { self?.onManagedRendererInvalidation?() }
            return event
        }
        let notifications: [Notification.Name] = [
            NSApplication.willResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willMoveNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        managedNotificationObservers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onManagedRendererInvalidation?() }
            }
        }
    }

    deinit {
        if let managedEventMonitor { NSEvent.removeMonitor(managedEventMonitor) }
        managedNotificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var alphaValue: CGFloat {
        willSet { if alphaValue != newValue { onManagedRendererInvalidation?() } }
    }

    override var isHidden: Bool {
        willSet { if isHidden != newValue { onManagedRendererInvalidation?() } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        event.cmuxIsUndoRedoCommandEquivalent
    }

    override func mouseDown(with event: NSEvent) {
        onManagedRendererInvalidation?()
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onManagedRendererInvalidation?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onManagedRendererInvalidation?()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        onManagedRendererInvalidation?()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        onManagedRendererInvalidation?()
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if frame.origin != newOrigin { onManagedRendererInvalidation?() }
        super.setFrameOrigin(newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { onManagedRendererInvalidation?() }
        super.setFrameSize(newSize)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        if bounds.origin != newOrigin { onManagedRendererInvalidation?() }
        super.setBoundsOrigin(newOrigin)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        if bounds.size != newSize { onManagedRendererInvalidation?() }
        super.setBoundsSize(newSize)
    }
}
