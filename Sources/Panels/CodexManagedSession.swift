import CmuxControlSocket
import Foundation

@MainActor
final class CodexManagedSession: AgentSessionManagedProviderAdapter {
    enum Phase {
        case awaitingDescriptor, initializing, configurationObserved, sending, awaitingRoot
        case executingCallback, respondingCallback, inspectingWork, workObserved, held
    }
    private(set) var phase: Phase = .awaitingDescriptor
    private(set) var holdReason: String?
    private(set) var diagnostics = Data()
    private(set) var closeFailures: [String] = []
    var failureSink: ((String) -> Void)?
    var projectionSink: ((AgentSessionManagedProjection) -> Void)?
    var configurationObserved: Bool { phase == .configurationObserved }
    var inputState: ShepherdManagedSessionState? { ledger?.state }
    var hasCompleteWorkEvidence: Bool {
        phase == .workObserved && pendingWrite == nil && commandTask == nil
            && ledger?.hasCompleteWorkEvidence == true && authorityIsLive
            && codingAuthority.outstandingWorkCount == 0
    }

    private enum Operation: Equatable { case initialize, input(UUID), callback(String), page }
    private struct PendingWrite {
        let id = UUID()
        let operation: Operation
    }
    private struct AutomaticAdmission {
        let submission: AgentSessionManagedRendererController.Submission
        let owner: AgentSessionManagedNativeOwner
        let store: AnyObject
        let identity: ShepherdManagedSessionIdentity
        let eventRevision: UUID
        let activityRevision: UUID
    }
    private let lifetime: AgentSessionManagedSession
    private let writer: ShepherdManagedPipeWriter
    private let workingDirectory: String
    private let nativeOwner: AgentSessionManagedNativeOwner
    private let codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority
    private var startup: CodexManagedStartup
    private var ledger: CodexManagedTurnLedger?
    private var pendingWrite: PendingWrite?
    private var awaitingResponse: Operation?
    private var writeTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var supervisorInputs: [UUID: AgentSessionManagedInputProgress] = [:]
    private var progressSinks: [UUID: (AgentSessionManagedInputProgress) -> Void] = [:]

    init(
        lifetime: AgentSessionManagedSession, takingOwnershipOf input: FileHandle,
        workingDirectory: String, bootNonce: UUID, nativeOwner: AgentSessionManagedNativeOwner,
        codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority
    ) throws {
        guard lifetime.declaredProvider == .codex, nativeOwner.provider == .codex,
              nativeOwner.authorizes(lifetime), lifetime.ownsWorkingDirectory(workingDirectory) else {
            throw CocoaError(.fileReadNoPermission)
        }
        self.lifetime = lifetime
        self.writer = try ShepherdManagedPipeWriter(takingOwnershipOf: input)
        self.workingDirectory = workingDirectory
        self.nativeOwner = nativeOwner
        self.codingAuthority = codingAuthority
        self.startup = CodexManagedStartup(bootNonce: bootNonce, workingDirectory: workingDirectory)
        lifetime.outputSink = { [weak self] stream, bytes, launchID in
            self?.receive(stream: stream, bytes: bytes, launchID: launchID)
        }
        lifetime.heldSink = { [weak self] _, launchID in
            guard let self, launchID == self.lifetime.launchID else { return }
            self.hold("transportUnavailable")
        }
    }

    deinit {
        writeTask?.cancel()
        responseTask?.cancel()
        commandTask?.cancel()
    }

    private var transportIsLive: Bool {
        nativeOwner.authorizes(lifetime) && lifetime.transportIsLive(launchID: lifetime.launchID)
    }
    private var authorityIsLive: Bool {
        transportIsLive && codingAuthority.isLive(for: lifetime, workingDirectory: workingDirectory)
    }

    func submitOwnerInput(_ inputID: UUID, prompt: String, launchID: UUID) -> Bool {
        guard launchID == lifetime.launchID, phase == .configurationObserved || phase == .workObserved,
              pendingWrite == nil, commandTask == nil,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard authorityIsLive, let ledger else {
            hold("commandAuthorityUnavailable")
            return false
        }
        guard let frame = ledger.beginInput(inputID, prompt: prompt) else {
            if let reason = ledger.failureReason { hold(reason) }
            return false
        }
        phase = .sending
        write(frame, operation: .input(inputID))
        return phase != .held
    }

    func beginSupervisorInput(
        _ submission: AgentSessionManagedRendererController.Submission,
        nativeOwner: AgentSessionManagedNativeOwner, owningStore: AnyObject,
        progress: ((AgentSessionManagedInputProgress) -> Void)?
    ) -> Bool {
        guard phase == .workObserved, hasCompleteWorkEvidence,
              supervisorInputs[submission.inputID] == nil, nativeOwner === self.nativeOwner,
              let identity = lifetime.identity, let ledger, ledger.state.identity == identity,
              nativeOwner.authorizes(lifetime), submission.claim(owner: nativeOwner, store: owningStore),
              hasCompleteWorkEvidence, submission.validate(owner: nativeOwner, store: owningStore),
              let frame = ledger.beginInput(submission.inputID, prompt: submission.text, origin: .supervisor) else {
            return false
        }
        let admission = AutomaticAdmission(
            submission: submission, owner: nativeOwner, store: owningStore, identity: identity,
            eventRevision: ledger.state.eventRevision, activityRevision: ledger.state.activityRevision)
        supervisorInputs[submission.inputID] = AgentSessionManagedInputProgress(
            inputID: submission.inputID, identity: identity)
        progressSinks[submission.inputID] = progress
        phase = .sending
        publishProgress(submission.inputID)
        guard automaticAdmissionIsCurrent(admission) else {
            hold("supervisorInputInvalidated")
            return false
        }
        write(frame, operation: .input(submission.inputID), admission: admission)
        return phase != .held
    }

    func supervisorInputProgress(_ inputID: UUID) -> AgentSessionManagedInputProgress? { supervisorInputs[inputID] }
    func waitForCommandSettlement() async { await commandTask?.value }

    private func publishProgress(_ id: UUID, terminal: Bool = false) {
        guard let value = supervisorInputs[id], let sink = progressSinks[id] else { return }
        if terminal { progressSinks.removeValue(forKey: id) }
        sink(value)
    }

    private func automaticAdmissionIsCurrent(_ admission: AutomaticAdmission) -> Bool {
        guard phase == .sending, let ledger,
              ledger.state.currentInputID == admission.submission.inputID,
              ledger.state.currentInputOrigin == .supervisor,
              ledger.state.eventRevision == admission.eventRevision,
              ledger.state.activityRevision == admission.activityRevision,
              lifetime.identity == admission.identity, authorityIsLive,
              admission.submission.validate(owner: admission.owner, store: admission.store) else { return false }
        return phase == .sending && ledger.state.eventRevision == admission.eventRevision
            && ledger.state.activityRevision == admission.activityRevision
    }

    private func receive(stream: String, bytes: Data, launchID: UUID) {
        guard launchID == lifetime.launchID, phase != .held else { return }
        guard transportIsLive else {
            hold("transportUnavailable")
            return
        }
        if stream == "stderr" {
            diagnostics.append(bytes.prefix(max(0, 8192 - diagnostics.count)))
            return
        }
        guard stream == "stdout" else {
            hold("unknownStream")
            return
        }
        if let ledger {
            ledger.receive(bytes)
            pump()
        } else {
            startup.receive(bytes)
            if let reason = startup.failureReason {
                hold(reason)
                return
            }
            if let frame = startup.initializeFrame() {
                phase = .initializing
                write(frame, operation: .initialize)
            }
            completeStartupIfProven()
        }
    }

    private func completeStartupIfProven() {
        guard phase != .held, ledger == nil, startup.configurationObserved else { return }
        guard let threadID = startup.threadID, startup.profileManifest != nil,
              transportIsLive, lifetime.acceptProviderHandshake(sessionID: threadID, launchID: lifetime.launchID),
              let identity = lifetime.identity, authorityIsLive else {
            hold("providerHandshakeUnavailable")
            return
        }
        ledger = CodexManagedTurnLedger(identity: identity, allowsForegroundCommands: true)
        phase = .configurationObserved
    }

    private func write(_ frame: Data, operation: Operation, admission: AutomaticAdmission? = nil) {
        guard phase != .held, pendingWrite == nil else {
            hold("writeLedgerConflict")
            return
        }
        let pending = PendingWrite(operation: operation)
        pendingWrite = pending
        writeTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.writer.write(
                frame, deadline: admission?.submission.deadline ?? .now.advanced(by: .seconds(2))
            ) {
                self.phase != .held && self.pendingWrite?.id == pending.id && self.transportIsLive
                    && (operation == .initialize || self.authorityIsLive)
                    && (admission.map { self.automaticAdmissionIsCurrent($0) } ?? true)
            }
            guard self.phase != .held else { return }
            guard self.pendingWrite?.id == pending.id, result == .complete(frame.count),
                  self.transportIsLive, operation == .initialize || self.authorityIsLive else {
                self.hold("writeUnavailable")
                return
            }
            self.pendingWrite = nil
            self.writeTask = nil
            let accepted: Bool
            switch operation {
            case .initialize: accepted = self.startup.initializeWritten()
            case .input(let id):
                self.supervisorInputs[id]?.backendWriteAdmitted = true
                self.publishProgress(id)
                guard self.phase != .held else { return }
                accepted = self.ledger?.inputWritten(id) == true
                self.phase = .awaitingRoot
            case .callback(let id): accepted = self.ledger?.callbackResponseWritten(id) == true
            case .page: accepted = self.ledger?.inspectionPageWritten() == true
            }
            guard accepted else {
                self.hold(self.ledger?.failureReason ?? self.startup.failureReason ?? "writeWitnessMismatch")
                return
            }
            if operation == .initialize {
                self.completeStartupIfProven()
            } else {
                self.watchResponse(operation)
                self.pump()
            }
        }
    }

    private func responseWasObserved(_ operation: Operation) -> Bool {
        guard let ledger else { return false }
        switch operation {
        case .initialize: return startup.configurationObserved
        case .input: return ledger.providerInputID != nil
        case .callback(let id): return ledger.callbackIsSettled(id)
        case .page: return !ledger.hasPendingInspectionPage
        }
    }

    private func watchResponse(_ operation: Operation) {
        guard !responseWasObserved(operation) else { return }
        guard awaitingResponse == nil else {
            hold("responseLedgerConflict")
            return
        }
        awaitingResponse = operation
        responseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { return }
            catch {
                self?.hold("responseTimerFailed")
                return
            }
            guard let self, self.awaitingResponse == operation else { return }
            self.hold("responseTimeout")
        }
    }

    private func pump() {
        guard phase != .held, let ledger else { return }
        guard authorityIsLive else {
            hold("commandAuthorityUnavailable")
            return
        }
        if let reason = ledger.failureReason {
            hold(reason)
            return
        }
        if let operation = awaitingResponse, responseWasObserved(operation) {
            awaitingResponse = nil
            responseTask?.cancel()
            responseTask = nil
        }
        if let id = ledger.state.currentInputID, let providerID = ledger.providerInputID,
           supervisorInputs[id] != nil, supervisorInputs[id]?.providerInputID == nil {
            supervisorInputs[id]?.providerInputID = providerID
            publishProgress(id, terminal: true)
        }
        guard phase != .held else { return }
        if ledger.hasCompleteWorkEvidence { phase = .workObserved }
        for projection in ledger.takeProjections() {
            switch projection {
            case .assistant(let text): guard publish(.assistant(text)) else { return }
            case .turnComplete: guard publish(.turnComplete) else { return }
            }
        }
        guard phase != .held, pendingWrite == nil, commandTask == nil, awaitingResponse == nil,
              !ledger.hasCompleteWorkEvidence else { return }
        if let callback = ledger.nextCallback {
            dispatch(callback)
        } else if ledger.canRequestShellPage {
            guard let frame = ledger.requestNextShellPage() else {
                hold(ledger.failureReason ?? "shellInspectionUnavailable")
                return
            }
            phase = .inspectingWork
            write(frame, operation: .page)
        }
    }

    private func publish(_ projection: AgentSessionManagedProjection) -> Bool {
        guard phase != .held, authorityIsLive else {
            hold("projectionOwnerUnavailable")
            return false
        }
        projectionSink?(projection)
        guard phase != .held, authorityIsLive else {
            hold("projectionOwnerUnavailable")
            return false
        }
        return true
    }

    private func dispatch(_ callback: CodexManagedTurnLedger.Callback) {
        guard authorityIsLive, let ledger, ledger.dispatchCallback(callback.callID) else {
            hold("commandAuthorityUnavailable")
            return
        }
        phase = .executingCallback
        guard publish(.commandStarted(callback.callID, callback.command)) else { return }
        let operationID = UUID()
        commandTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.codingAuthority.execute(callback.command, operationID: operationID)
            self.commandTask = nil
            guard self.phase != .held else { return }
            guard self.authorityIsLive else {
                self.hold("commandAuthorityUnavailable")
                return
            }
            switch outcome {
            case .held(let reason): self.hold("commandHeld:\(reason.rawValue)")
            case .completed(let completion):
                let report: [String: Any] = [
                    "status": completion.status, "stdout": completion.stdout.base64EncodedString(),
                    "stderr": completion.stderr.base64EncodedString(), "stdoutBytes": completion.stdout.count,
                    "stderrBytes": completion.stderr.count, "decoding": "base64",
                ]
                do {
                    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                    let text = String(decoding: bytes, as: UTF8.self)
                    guard let frame = ledger.commandCompleted(
                        callback.callID, text: text, success: completion.status == 0) else {
                        self.hold(ledger.failureReason ?? "commandResultUnavailable")
                        return
                    }
                    let display = String(decoding: completion.stdout + completion.stderr, as: UTF8.self)
                    guard self.publish(.commandCompleted(
                        callback.callID, callback.command, completion.status, display)) else { return }
                    self.phase = .respondingCallback
                    self.write(frame, operation: .callback(callback.callID))
                } catch { self.hold("commandResultEncodingFailed") }
            }
        }
    }

    private func hold(_ reason: String) {
        guard phase != .held else { return }
        phase = .held
        holdReason = reason
        ledger?.finishStream()
        for id in supervisorInputs.keys where supervisorInputs[id]?.providerInputID == nil {
            supervisorInputs[id]?.failureReason = reason
            publishProgress(id, terminal: true)
        }
        writeTask?.cancel()
        responseTask?.cancel()
        commandTask?.cancel()
        codingAuthority.revoke()
        do { try writer.close() } catch { closeFailures.append("stdin: \(error)") }
        do { try lifetime.abandon() } catch { closeFailures.append("output: \(error)") }
        failureSink?(reason)
    }
}
