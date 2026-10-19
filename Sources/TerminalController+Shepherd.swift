import CmuxControlSocket
import CmuxTerminal
import CryptoKit
import Foundation

extension TerminalController {
    nonisolated static func isShepherdSocketCommand(_ command: String) -> Bool {
        guard case .success(let request) = ControlRequestParser().request(fromLine: command) else { return false }
        return ShepherdControlRequest.Method(rawValue: request.method) != nil
    }

    nonisolated func handleShepherdRequestAsync(
        _ request: ControlRequest, peer: ShepherdControlPeer?
    ) async -> ControlCallResult {
        // Check the accepted socket and the original envelope before a relay
        // authorizer can sanitize provenance or any native actor hop can occur.
        guard let peer, peer.peerHasSameUID, !peer.isRemoteRelay,
              request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] == nil else {
            return .err(
                code: "access_denied",
                message: "Native Shepherd requires a verified same-user local peer.",
                data: nil
            )
        }
        let boundary = await shepherdControlBoundary
        return await boundary.handle(request, peer: peer)
    }

    func makeShepherdControlBoundary() -> ShepherdControlBoundary {
        let host = TerminalControllerShepherdHost(owner: self)
        return ShepherdControlBoundary(
            host: host,
            now: { ProcessInfo.processInfo.systemUptime },
            unixMilliseconds: { Int64(Date().timeIntervalSince1970 * 1_000) },
            readVisibleScreen: { workspaceID, surfaceID in
                host.readVisibleScreen(workspaceID: workspaceID, surfaceID: surfaceID)
            },
            wait: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            }
        )
    }
}

@MainActor
final class TerminalControllerShepherdHost: ShepherdAdmissionHost {
    private weak var owner: TerminalController?
    private let processEvidenceReader: ShepherdProcessEvidenceReader

    init(owner: TerminalController, processEvidenceReader: ShepherdProcessEvidenceReader? = nil) {
        self.owner = owner
        self.processEvidenceReader = processEvidenceReader ?? ShepherdProcessEvidenceReader(
            processStart: { [weak owner] pid in owner?.transport.processStartTime(of: pid)?.absoluteTime }
        )
    }

    func readVisibleScreen(workspaceID: UUID, surfaceID: UUID) -> String? {
        surface(workspaceID: workspaceID, surfaceID: surfaceID)?.readText(region: .screen)
    }

    func snapshot(workspaceID: UUID, surfaceID: UUID) -> ShepherdAdmissionSnapshot? {
        guard owner != nil, let surface = surface(workspaceID: workspaceID, surfaceID: surfaceID) else {
            return nil
        }
        let initialProcess = processEvidence(workspaceID: workspaceID, surfaceID: surfaceID)
        let initialScreen = surface.readText(region: .screen)
        let render = ShepherdRenderEvidence.capture(surface: surface, surfaceID: surfaceID, agent: initialProcess?.agent)
        let screen = surface.readText(region: .screen)
        let finalProcess = processEvidence(workspaceID: workspaceID, surfaceID: surfaceID)
        let stable = initialScreen == screen && initialProcess == finalProcess
        let composer: ShepherdComposerState
        switch stable ? render.state : .unknown {
        case .unknown: composer = .unknown
        case .empty: composer = .empty
        case .draft(let text): composer = .draft(text)
        case .dialog: composer = .dialog
        }
        let process = initialProcess == finalProcess ? finalProcess : nil
        return ShepherdAdmissionSnapshot(
            surfaceID: surfaceID, workspaceID: workspaceID,
            processInstance: process?.processInstance,
            surfaceGeneration: surface.runtimeSurfaceGeneration,
            screenFingerprint: stable ? screen.map {
                SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            } ?? "" : "",
            outsideComposerFingerprint: stable ? render.outsideComposerFingerprint : "",
            inputRevision: surface.shepherdInputRevision,
            focusRevision: surface.shepherdFocusRevision,
            focused: surface.isShepherdFocused,
            idle: nil, composer: composer, backgroundWork: nil,
            acceptsImmediateInput: surface.acceptsShepherdImmediateInput,
            agent: process?.agent, workingDirectory: process?.workingDirectory, tty: process?.tty
        )
    }

    func paste(
        request: ShepherdContinuationRequest,
        snapshot expected: ShepherdAdmissionSnapshot,
        expiresAt: TimeInterval
    ) -> ShepherdPasteWriteResult {
        guard snapshot(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) == expected,
              let surface = surface(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID),
              let revision = surface.sendShepherdPaste(
                  request.text, requestID: request.requestID, expiresAt: expiresAt
              ) else { return .notAdmitted }
        return .admitted(inputRevision: revision)
    }

    func submit(requestID: UUID, snapshot expected: ShepherdAdmissionSnapshot) -> Bool {
        guard snapshot(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) == expected,
              let surface = surface(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) else {
            return false
        }
        return surface.sendShepherdSubmit(requestID: requestID)
    }

    func releaseReservation(requestID: UUID, snapshot: ShepherdAdmissionSnapshot) {
        surface(workspaceID: snapshot.workspaceID, surfaceID: snapshot.surfaceID)?
            .finishShepherdInputReservation(requestID: requestID)
    }

    private func processEvidence(workspaceID: UUID, surfaceID: UUID) -> ShepherdProcessEvidence? {
        processEvidenceReader.read {
            guard let surface = surface(workspaceID: workspaceID, surfaceID: surfaceID),
                  let foregroundPID = surface.foregroundProcessID(),
                  let pid = Int32(exactly: foregroundPID),
                  let tty = surface.controllingTTYName(),
                  let device = surface.controllingTTYDeviceIdentifier else { return nil }
            return ShepherdProcessSurface(
                pid: pid, generation: surface.runtimeSurfaceGeneration, tty: tty, ttyDevice: device
            )
        }
    }

    private func surface(workspaceID: UUID, surfaceID: UUID) -> TerminalSurface? {
        guard owner != nil,
              let located = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: surfaceID, preferredWorkspaceId: workspaceID
              ), located.workspace.id == workspaceID,
              let panel = located.workspace.panels[surfaceID] as? TerminalPanel,
              panel.surface.owningTabId == workspaceID else { return nil }
        return panel.surface
    }
}
