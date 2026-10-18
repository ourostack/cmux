public import Foundation
public import GhosttyKit
internal import Carbon.HIToolbox

extension TerminalSurface {
    /// Excludes guarded admission across a synchronous physical input dispatch.
    ///
    /// Balance with ``endShepherdInputExclusion()`` using `defer`.
    @MainActor
    public func beginShepherdInputExclusion() {
        shepherdInputExclusionDepth += 1
    }

    /// Ends one synchronous input dispatch's guarded-admission exclusion.
    @MainActor
    public func endShepherdInputExclusion() {
        shepherdInputExclusionDepth -= 1
    }

    /// Invalidates guarded observations and cancels submission before physical input proceeds.
    @MainActor
    public func invalidateShepherdInput() {
        shepherdInputRevision &+= 1
        shepherdInputReservation = nil
    }

    /// Whether this runtime can accept guarded input without creating or queueing work.
    @MainActor
    public var acceptsShepherdImmediateInput: Bool {
        guard shepherdInputExclusionDepth == 0, !ioMode.usesManualIO, !sharingViewDetached,
              pendingSocketInputQueue.isEmpty, pendingSocketInputBytes == 0,
              !startupInputGate.hasPendingInput(generation: terminalLifecycleId),
              !runtimeSurfaceSuspendedForAgentHibernation,
              surfaceView.acceptsGuardedImmediateInput,
              let live = liveSurfaceForGhosttyAccess(reason: "shepherd.readiness") else { return false }
        return !ghostty_surface_process_exited(live)
    }

    /// Whether a nonexpired reservation currently excludes other programmatic writes.
    @MainActor
    public var hasShepherdInputReservation: Bool {
        guard let reservation = shepherdInputReservation else { return false }
        guard ProcessInfo.processInfo.systemUptime < reservation.deadline,
              runtimeSurfaceGeneration == reservation.generation else {
            shepherdInputReservation = nil
            return false
        }
        return true
    }

    /// Releases only the named reservation; stale completions cannot release a newer one.
    ///
    /// - Parameter requestID: The request whose reservation should end.
    @MainActor
    public func finishShepherdInputReservation(requestID: UUID) {
        if shepherdInputReservation?.id == requestID {
            shepherdInputReservation = nil
        }
    }

    /// Admits one literal paste to a live runtime and retains its submit reservation.
    ///
    /// - Parameters:
    ///   - text: Bounded, single-line literal text.
    ///   - requestID: The admission kernel's idempotent request identity.
    ///   - expiresAt: The observation's deadline in system uptime, within two seconds.
    /// - Returns: The post-admission input revision, or nil if no input was admitted.
    @MainActor
    public func sendShepherdPaste(_ text: String, requestID: UUID, expiresAt: TimeInterval) -> UInt64? {
        let now = ProcessInfo.processInfo.systemUptime
        guard expiresAt.isFinite, expiresAt > now, expiresAt <= now + 2,
              !hasShepherdInputReservation, acceptsShepherdImmediateInput,
              !desiredFocusState,
              shepherdLastFocusedAt.map({ now - $0 >= 60 }) ?? true,
              !text.isEmpty, text.count <= 2000, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029
              }),
              let data = text.data(using: .utf8),
              let live = liveSurfaceForGhosttyAccess(reason: "shepherd.paste") else { return nil }
        beginShepherdInputExclusion()
        defer { endShepherdInputExclusion() }
        shepherdInputReservation = (requestID, expiresAt, runtimeSurfaceGeneration)
        shepherdInputRevision &+= 1
        let admittedRevision = shepherdInputRevision
        writeTextData(data, to: live)
        didAcceptExplicitInput()
        hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        return admittedRevision
    }

    /// Admits Enter only for a still-live reservation after external editor verification.
    ///
    /// The admission kernel owns the minimum paste/submit separation and exact render
    /// check. This transport never queues, recreates a surface, or clears a composer.
    ///
    /// - Parameter requestID: The reservation whose submit is being admitted.
    /// - Returns: Whether the live runtime handled the submit stroke.
    @MainActor
    public func sendShepherdSubmit(requestID: UUID) -> Bool {
        guard hasShepherdInputReservation, shepherdInputReservation?.id == requestID,
              acceptsShepherdImmediateInput, !desiredFocusState,
              let live = liveSurfaceForGhosttyAccess(reason: "shepherd.submit") else { return false }
        beginShepherdInputExclusion()
        defer { endShepherdInputExclusion() }
        shepherdInputReservation = nil
        shepherdInputRevision &+= 1
        let handled = sendKeyEvent(surface: live, keycode: UInt32(kVK_Return))
        if handled {
            didAcceptExplicitInput()
            hibernationRecorder.recordTerminalInput(workspaceId: tabId, panelId: id)
        }
        return handled
    }
}
