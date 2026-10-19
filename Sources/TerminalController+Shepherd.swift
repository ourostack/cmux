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
        let boot = UUID()
        let host = TerminalControllerShepherdHost(owner: self, hostInstance: boot)
        return ShepherdControlBoundary(
            host: host,
            hostInstance: boot,
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
    private let hostInstance: UUID
    private let readinessStoreData: () throws -> Data?
    private let qualifiedAgents: Set<String>
    private let qualifiedBinaries: [String: Set<String>]

    init(
        owner: TerminalController, processEvidenceReader: ShepherdProcessEvidenceReader? = nil,
        hostInstance: UUID = UUID(), readinessStoreData: (() throws -> Data?)? = nil,
        qualifiedAgents: Set<String> = ShepherdHookLaunchPolicy.qualifiedAgents,
        qualifiedBinaries: [String: Set<String>] = ShepherdHookLaunchPolicy.qualifiedBinaries
    ) {
        self.owner = owner
        self.hostInstance = hostInstance
        self.readinessStoreData = readinessStoreData ?? { try ShepherdHookReadinessProof.loadStoreData() }
        self.qualifiedAgents = qualifiedAgents
        self.qualifiedBinaries = qualifiedBinaries
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
        let initialStore = readReadinessStore()
        let initialProcess = processEvidence(
            workspaceID: workspaceID, surfaceID: surfaceID, storeData: initialStore
        )
        let initialBinary = binaryIdentity(initialProcess)
        let initialRevision = surface.shepherdInputRevision
        let readinessRevision = surface.shepherdReadinessObservationRevision
        let initialScreen = surface.readText(region: .screen)
        let render = ShepherdRenderEvidence.capture(surface: surface, surfaceID: surfaceID, agent: initialProcess?.agent)
        let screen = surface.readText(region: .screen)
        let finalProcess = processEvidence(
            workspaceID: workspaceID, surfaceID: surfaceID, storeData: initialStore
        )
        let finalBinary = binaryIdentity(finalProcess)
        let finalStore = readReadinessStore()
        let stable = initialScreen == screen && initialProcess == finalProcess
        let readiness: ShepherdHookProducerProof?
        if stable, initialRevision == surface.shepherdInputRevision,
           readinessRevision == surface.shepherdReadinessObservationRevision,
           let process = finalProcess, process.agent == "claude",
           initialStore == finalStore, let data = finalStore {
            let scope = ShepherdHookReadinessScope(
                hostInstance: hostInstance, workspaceID: workspaceID, surfaceID: surfaceID,
                processInstance: process.processInstance, pid: process.surface.pid,
                pidStartSeconds: process.birth.startSeconds, pidStartMicroseconds: process.birth.startMicroseconds,
                surfaceGeneration: process.surface.generation, inputRevision: readinessRevision
            )
            do {
                if let state = try ShepherdHookProducerState.readStore(
                    data, matching: scope, qualifiedBinaries: qualifiedBinaries
                ), state.launch.executablePath == process.executablePath,
                   let initialBinary, let finalBinary {
                    let before = try initialBinary.get()
                    let after = try finalBinary.get()
                    readiness = before == after && state.launch.executableIdentity == after
                        ? state.proof(matching: scope, qualifiedBinaries: qualifiedBinaries) : nil
                } else {
                    readiness = nil
                }
            } catch {
                NSLog("Shepherd readiness unavailable: hook session or executable evidence could not be verified.")
                readiness = nil
            }
        } else {
            readiness = nil
        }
        var outside = stable ? render.outsideComposerFingerprint : ""
        if !outside.isEmpty, let readiness {
            outside = SHA256.hash(data: Data(
                "cmux.shepherd.readiness.v2\u{0}\(outside)\u{0}\(readiness.nonce.uuidString)".utf8
            )).map { String(format: "%02x", $0) }.joined()
        }
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
            outsideComposerFingerprint: outside,
            inputRevision: surface.shepherdInputRevision,
            focusRevision: surface.shepherdFocusRevision,
            focused: surface.isShepherdFocused,
            idle: readiness == nil ? nil : true, composer: composer,
            backgroundWork: readiness == nil ? nil : false,
            acceptsImmediateInput: process.map { qualifiedAgents.contains($0.agent) } == true
                && surface.acceptsShepherdImmediateInput,
            agent: process?.agent, workingDirectory: process?.workingDirectory, tty: process?.tty
        )
    }

    private func readReadinessStore() -> Data? {
        do {
            return try readinessStoreData()
        } catch {
            NSLog("Shepherd readiness unavailable: hook session store could not be read safely.")
            return nil
        }
    }

    func paste(
        request: ShepherdContinuationRequest,
        snapshot expected: ShepherdAdmissionSnapshot,
        expiresAt: TimeInterval
    ) -> ShepherdPasteWriteResult {
        guard expected.acceptsImmediateInput,
              snapshot(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) == expected,
              let surface = surface(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID),
              let revision = surface.sendShepherdPaste(
                  request.text, requestID: request.requestID, expiresAt: expiresAt
              ) else { return .notAdmitted }
        return .admitted(inputRevision: revision)
    }

    func submit(requestID: UUID, snapshot expected: ShepherdAdmissionSnapshot) -> Bool {
        guard expected.acceptsImmediateInput,
              snapshot(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) == expected,
              let surface = surface(workspaceID: expected.workspaceID, surfaceID: expected.surfaceID) else {
            return false
        }
        return surface.sendShepherdSubmit(requestID: requestID)
    }

    func releaseReservation(requestID: UUID, snapshot: ShepherdAdmissionSnapshot) {
        surface(workspaceID: snapshot.workspaceID, surfaceID: snapshot.surfaceID)?
            .finishShepherdInputReservation(requestID: requestID)
    }

    private func binaryIdentity(
        _ process: ShepherdProcessEvidence?
    ) -> Result<ShepherdHookExecutableIdentity, Error>? {
        guard !qualifiedBinaries.isEmpty, let process else { return nil }
        return Result { try ShepherdHookExecutableIdentity.capture(path: process.executablePath) }
    }

    private func processEvidence(
        workspaceID: UUID, surfaceID: UUID, storeData: Data?
    ) -> ShepherdProcessEvidence? {
        let launch: ShepherdHookLaunchReceipt?
        do {
            if let storeData, !qualifiedBinaries.isEmpty {
                launch = try ShepherdHookProducerState.readRegisteredLaunch(
                    storeData, hostInstance: hostInstance, workspaceID: workspaceID, surfaceID: surfaceID,
                    qualifiedBinaries: qualifiedBinaries
                )
            } else {
                launch = nil
            }
        } catch {
            NSLog("Shepherd root unavailable: launch registration could not be decoded safely.")
            launch = nil
        }
        var reader = processEvidenceReader
        reader.registeredClaudeRoot = { pid, path, birth in
            guard let launch, launch.pid == pid, launch.executablePath == path,
                  launch.pidStartSeconds == birth.startSeconds,
                  launch.pidStartMicroseconds == birth.startMicroseconds,
                  let identity = launch.executableIdentity else { return false }
            do {
                return try ShepherdHookExecutableIdentity.capture(path: path) == identity
            } catch {
                NSLog("Shepherd root unavailable: registered executable identity could not be verified.")
                return false
            }
        }
        return reader.read {
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
