import Foundation
import CMUXMobileCore

@MainActor public final class TerminalSurface {
    public var owningTabId: UUID
    public var runtimeSurfaceGeneration: UInt64 = 1
    public var shepherdInputRevision: UInt64 = 0
    public var shepherdFocusRevision: UInt64 = 0
    var desiredFocusState = false
    public var shepherdLastFocusedAt: TimeInterval?
    var shepherdInputReservation: (
        id: UUID, deadline: TimeInterval, generation: UInt64,
        baseRevision: UInt64, expectedRevision: UInt64
    )?
    var shepherdInputExclusionDepth = 0
    var ioMode = IOMode()
    var sharingViewDetached = false
    var pendingSocketInputQueue: [Int] = []
    var pendingSocketInputBytes = 0
    var startupInputGate = StartupGate()
    var terminalLifecycleId: UInt64 = 1
    var runtimeSurfaceSuspendedForAgentHibernation = false
    var surfaceView = SurfaceView()
    var tabId: UUID { owningTabId }
    var id = UUID()
    var hibernationRecorder = HibernationRecorder()
    public var onWrite: (() -> Void)?
    public var screen: String? = "abc"
    public var pastes: [String] = []
    public var submits: [UUID] = []
    public var releases: [UUID] = []
    public var foregroundPID: Int?
    public var ttyName: String? = "/dev/ttys123"
    public var controllingTTYDeviceIdentifier: Int64? = 123
    public var onReadScreen: (() -> Void)?
    public var onReadGrid: (() -> Void)?
    public var renderFrame: MobileTerminalRenderGridFrame?
    public init(workspaceID: UUID) { owningTabId = workspaceID }
    public func foregroundProcessID() -> Int? { foregroundPID }
    public func controllingTTYName() -> String? { ttyName }
    public func readText(region: Region) -> String? { onReadScreen?(); return screen }
    public func mobileRenderGridFrame(
        stateSeq: UInt64, includeTheme: Bool, anchor: MobileTerminalRenderGridFrame.Anchor
    ) -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        onReadGrid?()
        guard let renderFrame else { return nil }
        return (renderFrame, [])
    }
    public enum Region { case screen }
    func liveSurfaceForGhosttyAccess(reason: String) -> Int? { 1 }
    func writeTextData(_ data: Data, to live: Int) {
        pastes.append(String(decoding: data, as: UTF8.self))
        onWrite?()
    }
    func sendKeyEvent(surface: Int, keycode: UInt32) -> Bool {
        submits.append(UUID())
        onWrite?()
        return true
    }
    func didAcceptExplicitInput() {}
    struct IOMode { var usesManualIO = false }
    struct StartupGate { func hasPendingInput(generation: UInt64) -> Bool { false } }
    struct SurfaceView { var acceptsGuardedImmediateInput = true }
    struct HibernationRecorder {
        func recordTerminalInput(workspaceId: UUID, panelId: UUID) {}
    }
}
