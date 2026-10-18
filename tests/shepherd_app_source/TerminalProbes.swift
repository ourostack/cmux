import Foundation

@MainActor public final class TerminalSurface {
    public var owningTabId: UUID
    public var runtimeSurfaceGeneration: UInt64 = 1
    public var shepherdInputRevision: UInt64 = 0
    public var shepherdFocusRevision: UInt64 = 0
    public var isShepherdFocused = false
    public var acceptsShepherdImmediateInput = true
    public var screen: String? = "abc"
    public var pastes: [String] = []
    public var submits: [UUID] = []
    public var releases: [UUID] = []
    public var foregroundPID: Int?
    public var ttyName: String? = "/dev/ttys123"
    public var controllingTTYDeviceIdentifier: Int64? = 123
    public var onReadScreen: (() -> Void)?
    public init(workspaceID: UUID) { owningTabId = workspaceID }
    public func foregroundProcessID() -> Int? { foregroundPID }
    public func controllingTTYName() -> String? { ttyName }
    public func readText(region: Region) -> String? { onReadScreen?(); return screen }
    public enum Region { case screen }
    public func sendShepherdPaste(_ text: String, requestID: UUID, expiresAt: TimeInterval) -> UInt64? {
        pastes.append(text)
        shepherdInputRevision += 1
        return shepherdInputRevision
    }
    public func sendShepherdSubmit(requestID: UUID) -> Bool {
        submits.append(requestID)
        return true
    }
    public func finishShepherdInputReservation(requestID: UUID) { releases.append(requestID) }
}
