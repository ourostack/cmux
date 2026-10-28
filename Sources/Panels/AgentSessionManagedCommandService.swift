import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

/// A native, foreground-only execution domain. This is not a profile qualification.
/// Keep one per owner generation: known completions permit reuse; held work never does.
@MainActor
final class AgentSessionManagedCommandService {
    typealias Command = AgentSessionManagedCommand

    /// Native-only, revocable opt-in. It deliberately grants OS-account command authority,
    /// not a filesystem sandbox or a semantic program/argument allowlist.
    @MainActor final class NativeCodingAuthority {
        enum Descriptor {
            case generalPurposeForegroundOSAccount
        }

        let descriptor: Descriptor = .generalPurposeForegroundOSAccount
        let projectMandate: UUID
        let launchID: UUID
        let workingDirectory: String
        private let lifetime: AgentSessionManagedSession
        private let host: AgentPIDProcessIdentity
        private let launcher: AgentSessionOwnedProcessLauncher
        private let environment: [String: String]
        private let validateNativeOwner: @MainActor () -> Bool
        private var revoked = false
        private var keptService: AgentSessionManagedCommandService?

        init?(
            explicitNativeCodingOptInFor lifetime: AgentSessionManagedSession,
            projectMandate: UUID, workingDirectory: String,
            launcher: AgentSessionOwnedProcessLauncher, environment: [String: String],
            validateNativeOwner: @escaping @MainActor () -> Bool = { true }
        ) {
            guard lifetime.ownsWorkingDirectory(workingDirectory),
                  let host = AgentPIDProcessIdentity(pid: getpid()) else { return nil }
            self.lifetime = lifetime
            self.projectMandate = projectMandate
            self.launchID = lifetime.launchID
            self.workingDirectory = workingDirectory
            self.host = host
            self.launcher = launcher
            self.environment = environment
            self.validateNativeOwner = validateNativeOwner
        }

        func revoke() { revoked = true }

        func isLive(for lifetime: AgentSessionManagedSession, workingDirectory: String) -> Bool {
            !revoked && self.lifetime === lifetime && self.workingDirectory == workingDirectory
                && AgentPIDProcessIdentity(pid: getpid()) == host
                && validateNativeOwner()
                && lifetime.transportIsLive(launchID: launchID) && lifetime.identity != nil
        }

        var outstandingWorkCount: Int { keptService?.outstandingWorkCount ?? 0 }

        func execute(_ command: Command, operationID: UUID) async -> Outcome {
            guard isLive(for: lifetime, workingDirectory: workingDirectory) else {
                return .held(.ownerUnavailable)
            }
            if keptService == nil {
                keptService = AgentSessionManagedCommandService(
                    launcher: launcher, workingDirectory: workingDirectory, environment: environment,
                    validateOwner: { [weak self] in
                        guard let self else { return false }
                        return self.isLive(for: self.lifetime, workingDirectory: self.workingDirectory)
                    }
                )
            }
            guard let keptService else { return .held(.ownerUnavailable) }
            return await keptService.execute(command, operationID: operationID)
        }
    }

    enum Hold: String {
        case registryConflict, ownerUnavailable, launchFailed, bootstrapUnavailable
        case readyUnavailable, cancelled, executionDeadline, outputLimit
        case stdoutReadFailed, stderrReadFailed, uncertainTermination, cleanupFailed
    }

    struct Completion {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let receipt: ShepherdManagedBackendLaunchReceipt
        let stages: [String]
    }

    enum Outcome {
        case completed(Completion)
        case held(Hold)
    }

    @MainActor private final class Work {
        let nonce = UUID()
        var process: Process?
        var supervisor: AgentPIDProcessIdentity?
        var binding: ShepherdManagedBackendBinding?
        var writer: ShepherdManagedPipeWriter?
        var stdout: AgentSessionManagedOutputReader?
        var stderr: ShepherdManagedBootstrapReader?
        var exitSource: (any DispatchSourceProcess)?
        var backendExited = false
        var termination: (status: Int32, normal: Bool)?
        var stdoutEOF = false
        var stderrEOF = false
        var stdoutFinished = false
        var stderrFinished = false
        var output = Data()
        var diagnostics = Data()
        var hold: Hold?
        var terminationRequested = false
        var stages = ["registered"]
        var task: Task<Outcome, Never>?
    }

    private let launcher: AgentSessionOwnedProcessLauncher
    private let workingDirectory: String
    private let environment: [String: String]
    private let validateOwner: @MainActor () -> Bool
    private var work: [UUID: Work] = [:]
    private var retainedIDs: Set<UUID> = []
    private var registryFailed = false
    private static let maximumOutputBytes = 256 * 1024

    var outstandingWorkCount: Int { work.count }

    func stages(for operationID: UUID) -> [String] { work[operationID]?.stages ?? [] }

    init(
        launcher: AgentSessionOwnedProcessLauncher, workingDirectory: String,
        environment: [String: String], validateOwner: @escaping @MainActor () -> Bool
    ) {
        self.launcher = launcher
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.validateOwner = validateOwner
    }

    func execute(_ command: Command, operationID: UUID) async -> Outcome {
        guard !registryFailed, work.isEmpty, !retainedIDs.contains(operationID), retainedIDs.count < 4096 else {
            registryFailed = true
            for current in work.values { hold(.registryConflict, current: current) }
            return .held(.registryConflict)
        }
        retainedIDs.insert(operationID)
        let current = Work()
        work[operationID] = current
        if Task.isCancelled { current.hold = .cancelled }
        let task = Task { await self.run(command, operationID: operationID, current: current) }
        current.task = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.cancel(operationID) }
        }
    }

    private func cancel(_ operationID: UUID) {
        guard let current = work[operationID] else { return }
        hold(.cancelled, current: current)
    }

    private func run(_ command: Command, operationID: UUID, current: Work) async -> Outcome {
        guard current.hold == nil, validateOwner() else {
            return finishHeld(current.hold ?? .ownerUnavailable, current: current)
        }
        let executableIdentity: ShepherdHookExecutableIdentity
        do {
            executableIdentity = try .capture(path: command.executableURL.path)
            let process = try launcher.prepareForeground(
                nonce: current.nonce, executableURL: command.executableURL, arguments: command.arguments,
                workingDirectory: workingDirectory, environment: environment
            )
            current.process = process
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            current.writer = try ShepherdManagedPipeWriter(takingOwnershipOf: input.fileHandleForWriting)
            current.stdout = try AgentSessionManagedOutputReader(takingOwnershipOf: output.fileHandleForReading)
            current.stderr = try ShepherdManagedBootstrapReader(takingOwnershipOf: error.fileHandleForReading)
            process.terminationHandler = { process in
                let status = process.terminationStatus
                let normal = process.terminationReason == .exit
                Task { @MainActor in
                    current.termination = (status, normal)
                    current.stages.append("supervisorExit")
                }
            }
            guard validateOwner(), current.hold == nil else {
                return finishHeld(.ownerUnavailable, current: current)
            }
            try process.run()
            if let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) {
                current.supervisor = supervisor
            } else {
                hold(.bootstrapUnavailable, current: current)
            }
            current.stages.append("launched")
        } catch {
            hold(.launchFailed, current: current)
            return finishHeld(.launchFailed, current: current)
        }

        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while current.binding == nil && current.hold == nil {
            guard validateOwner() else {
                hold(.ownerUnavailable, current: current)
                break
            }
            if ContinuousClock.now >= startupDeadline {
                hold(.bootstrapUnavailable, current: current)
                break
            }
            switch current.stderr?.readNext() {
            case .waiting:
                break
            case .receipt(let receipt):
                do {
                    guard let supervisor = current.supervisor else { throw POSIXError(.ESRCH) }
                    let binding = try receipt.bind(
                        expectedNonce: current.nonce, expectedSupervisor: supervisor,
                        executableURL: command.executableURL, executableIdentity: executableIdentity,
                        workingDirectory: workingDirectory
                    )
                    current.binding = binding
                    current.stages.append("bound")
                    let source = DispatchSource.makeProcessSource(
                        identifier: receipt.backend.pid, eventMask: .exit, queue: .main
                    )
                    source.setEventHandler {
                        Task { @MainActor in
                            current.backendExited = true
                            current.stages.append("backendExit")
                        }
                    }
                    current.exitSource = source
                    source.resume()
                    try binding.revalidate()
                    current.stages.append("observing")
                } catch {
                    hold(.bootstrapUnavailable, current: current)
                }
            default:
                hold(.bootstrapUnavailable, current: current)
            }
            if current.binding == nil { await pause() }
        }
        if current.hold == nil, let writer = current.writer {
            var nonce = current.nonce.uuid
            let ready = Data("CMXGO001".utf8) + withUnsafeBytes(of: &nonce) { Data($0) }
            let result = await writer.write(ready, deadline: .now.advanced(by: .seconds(1))) {
                guard current.hold == nil, self.work[operationID] === current, self.validateOwner(),
                      let binding = current.binding else { return false }
                do { try binding.revalidate(); return true }
                catch { return false }
            }
            if result == .complete(ready.count) {
                do {
                    try writer.close()
                    current.stages.append("ready")
                } catch {
                    hold(.readyUnavailable, current: current)
                }
            } else {
                hold(.readyUnavailable, current: current)
            }
        }
        if current.hold != nil {
            do { try current.writer?.close() } catch { hold(.cleanupFailed, current: current) }
        }
        let executionDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while true {
            if !validateOwner() { hold(.ownerUnavailable, current: current) }
            if ContinuousClock.now >= executionDeadline { hold(.executionDeadline, current: current) }
            consume(current)
            if current.termination != nil && current.stdoutFinished && current.stderrFinished {
                if current.backendExited || current.hold != nil { break }
            }
            await pause()
        }
        if current.stdoutEOF && current.stderrEOF { current.stages.append("drained") }
        if let termination = current.termination, !termination.normal || termination.status == 254 {
            hold(.uncertainTermination, current: current)
        }
        if !validateOwner() { hold(.ownerUnavailable, current: current) }
        close(current)
        current.task = nil
        if let held = current.hold { return .held(held) }
        guard let termination = current.termination, let binding = current.binding, current.backendExited,
              current.stdoutEOF, current.stderrEOF else {
            return finishHeld(.uncertainTermination, current: current)
        }
        work.removeValue(forKey: operationID)
        return .completed(Completion(
            status: termination.status, stdout: current.output, stderr: current.diagnostics,
            receipt: binding.receipt, stages: current.stages
        ))
    }

    private func consume(_ current: Work) {
        if !current.stdoutFinished {
            switch current.stdout?.readNext() {
            case .waiting: break
            case .bytes(let bytes):
                append(bytes, to: &current.output, current: current)
            case .endOfFile:
                current.stdoutEOF = true
                current.stdoutFinished = true
            default:
                current.stdoutFinished = true
                hold(.stdoutReadFailed, current: current)
            }
        }
        if !current.stderrFinished {
            switch current.stderr?.readNext() {
            case .waiting: break
            case .providerStderr(let bytes):
                append(bytes, to: &current.diagnostics, current: current)
            case .endOfFile:
                current.stderrEOF = true
                current.stderrFinished = true
            default:
                current.stderrFinished = true
                hold(.stderrReadFailed, current: current)
            }
        }
    }

    private func append(_ bytes: Data, to output: inout Data, current: Work) {
        let remaining = Self.maximumOutputBytes - output.count
        output.append(bytes.prefix(max(0, remaining)))
        if bytes.count > remaining { hold(.outputLimit, current: current) }
    }

    private func hold(_ reason: Hold, current: Work) {
        if current.hold == nil { current.hold = reason }
        guard !current.terminationRequested, let process = current.process, process.isRunning else { return }
        guard let supervisor = current.supervisor,
              AgentPIDProcessIdentity(pid: supervisor.pid) == supervisor else { return }
        current.terminationRequested = true
        process.terminate()
    }

    private func close(_ current: Work) {
        current.exitSource?.cancel()
        current.exitSource = nil
        current.process?.terminationHandler = nil
        do { try current.writer?.close() } catch { hold(.cleanupFailed, current: current) }
        do { try current.stdout?.close() } catch { hold(.cleanupFailed, current: current) }
        do { try current.stderr?.close() } catch { hold(.cleanupFailed, current: current) }
        current.writer = nil
        current.stdout = nil
        current.stderr = nil
        current.process = nil
    }

    private func finishHeld(_ reason: Hold, current: Work) -> Outcome {
        hold(reason, current: current)
        close(current)
        current.task = nil
        return .held(current.hold ?? reason)
    }

    private func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) { continuation.resume() }
        }
    }
}
