import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

enum AgentSessionManagedOutputRead: Equatable {
    case waiting
    case bytes(Data)
    case endOfFile
    case failed(Int32)
    case closed
}

@MainActor
final class AgentSessionManagedOutputReader {
    private let handle: FileHandle
    private var terminal: AgentSessionManagedOutputRead?
    private var isClosed = false

    init(takingOwnershipOf source: FileHandle) throws {
        let descriptor = fcntl(source.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ShepherdManagedPipeSetupError.systemCall(errno) }
        var needsClose = true
        defer { if needsClose { Darwin.close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ShepherdManagedPipeSetupError.systemCall(errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else {
            throw ShepherdManagedPipeSetupError.notPipe
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ShepherdManagedPipeSetupError.systemCall(errno)
        }
        try source.close()
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        needsClose = false
    }

    func readNext() -> AgentSessionManagedOutputRead {
        if let terminal { return terminal }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var count: Int
        repeat {
            count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        } while count < 0 && errno == EINTR
        if count < 0 {
            let failure = errno
            if failure == EAGAIN || failure == EWOULDBLOCK { return .waiting }
            terminal = .failed(failure)
        } else if count == 0 {
            terminal = .endOfFile
        } else {
            return .bytes(Data(bytes.prefix(count)))
        }
        return terminal!
    }

    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        if terminal == nil { terminal = .closed }
        try handle.close()
    }
}

enum AgentSessionManagedPhase: Equatable {
    case awaitingBootstrap
    case awaitingProvider
    case bound
    case held
}

enum AgentSessionManagedLifetimeHold: Equatable {
    case bootstrapUnavailable
    case providerHandshakeUnavailable
    case conflictingProviderSession
    case backendUnavailable
    case streamEnded
    case stdoutReadFailed(Int32)
    case stderrReadFailed(ShepherdManagedBootstrapError)
    case abandoned
}

/// Native launch ownership only. A bound provider identity does not qualify a profile or admit input.
@MainActor
final class AgentSessionManagedSession {
    let launchID = UUID()
    private(set) var phase: AgentSessionManagedPhase = .awaitingBootstrap
    private(set) var holdReason: AgentSessionManagedLifetimeHold?
    private(set) var backendIdentity: AgentPIDProcessIdentity?
    var outputSink: ((String, Data, UUID) -> Void)?
    var heldSink: ((AgentSessionManagedLifetimeHold, UUID) -> Void)?

    private let nonce: UUID
    private let hostInstance: UUID
    private let workspaceID: UUID
    private let surfaceID: UUID
    private let surfaceGeneration: UInt64
    private let provider: ShepherdManagedProvider
    private let executableURL: URL
    private let executableIdentity: ShepherdHookExecutableIdentity
    private let executableSHA256: String
    private let profileSHA256: String
    private let workingDirectory: String
    private let stdout: AgentSessionManagedOutputReader
    private let stderr: ShepherdManagedBootstrapReader
    private var supervisor: AgentPIDProcessIdentity?
    private var binding: ShepherdManagedBackendBinding?
    private var boundIdentity: ShepherdManagedSessionIdentity?
    private var deadline = ContinuousClock.now.advanced(by: .seconds(5))
    private var monitoringTask: Task<Void, Never>?
    private var backendExitSource: (any DispatchSourceProcess)?
    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutFinished = false
    private var stderrFinished = false
    private var abandoned = false

    var hasActuallyDrainedStreams: Bool { stdoutEOF && stderrEOF }

    var identity: ShepherdManagedSessionIdentity? {
        guard phase == .bound, validateBackend() else { return nil }
        return boundIdentity
    }

    init(
        nonce: UUID, hostInstance: UUID, workspaceID: UUID, surfaceID: UUID,
        surfaceGeneration: UInt64, provider: ShepherdManagedProvider,
        executableURL: URL, executableIdentity: ShepherdHookExecutableIdentity,
        executableSHA256: String, profileSHA256: String, workingDirectory: String,
        stdout: FileHandle, stderr: FileHandle
    ) throws {
        self.nonce = nonce
        self.hostInstance = hostInstance
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.provider = provider
        self.executableURL = executableURL
        self.executableIdentity = executableIdentity
        self.executableSHA256 = executableSHA256
        self.profileSHA256 = profileSHA256
        self.workingDirectory = workingDirectory
        self.stdout = try AgentSessionManagedOutputReader(takingOwnershipOf: stdout)
        self.stderr = try ShepherdManagedBootstrapReader(takingOwnershipOf: stderr)
    }

    deinit { monitoringTask?.cancel() }

    func transportIsLive(launchID: UUID) -> Bool {
        guard launchID == self.launchID,
              phase == .awaitingProvider || phase == .bound else { return false }
        return validateBackend()
    }

    func attach(supervisor: AgentPIDProcessIdentity) throws {
        guard self.supervisor == nil, phase == .awaitingBootstrap,
              let snapshot = AgentPIDProcessIdentity.processSnapshot(pid: supervisor.pid),
              snapshot.identity == supervisor, snapshot.parentPID == getpid() else {
            hold(.bootstrapUnavailable)
            throw ShepherdManagedBootstrapError.supervisorMismatch
        }
        self.supervisor = supervisor
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
        }
    }

    /// Called only by the strict native provider adapter after its real initialization response.
    @discardableResult
    func acceptProviderHandshake(sessionID: String, launchID: UUID) -> Bool {
        guard launchID == self.launchID, phase != .held else { return false }
        guard phase == .awaitingProvider || phase == .bound else {
            hold(.providerHandshakeUnavailable)
            return false
        }
        guard phase == .bound || ContinuousClock.now < deadline else {
            hold(.providerHandshakeUnavailable)
            return false
        }
        guard validateBackend(), let backendIdentity,
              let microseconds = Int32(exactly: backendIdentity.startMicroseconds),
              let identity = ShepherdManagedSessionIdentity(
                  hostInstance: hostInstance, workspaceID: workspaceID, surfaceID: surfaceID,
                  backendPID: backendIdentity.pid, backendStartSeconds: backendIdentity.startSeconds,
                  backendStartMicroseconds: microseconds, provider: provider, providerSessionID: sessionID,
                  surfaceGeneration: surfaceGeneration,
                  executableSHA256: executableSHA256, profileSHA256: profileSHA256
              ) else {
            hold(.providerHandshakeUnavailable)
            return false
        }
        if let boundIdentity, boundIdentity != identity {
            hold(.conflictingProviderSession)
            return false
        }
        boundIdentity = identity
        phase = .bound
        return true
    }

    func abandon() throws {
        guard !abandoned else { return }
        abandoned = true
        hold(.abandoned)
        monitoringTask?.cancel()
        backendExitSource?.cancel()
        var closeError: (any Error)?
        do { try stdout.close() } catch { closeError = error }
        do { try stderr.close() } catch { if closeError == nil { closeError = error } }
        if let closeError { throw closeError }
    }

    private func poll() {
        guard !abandoned else { return }
        if phase == .awaitingBootstrap || phase == .awaitingProvider,
           ContinuousClock.now >= deadline {
            hold(phase == .awaitingBootstrap ? .bootstrapUnavailable : .providerHandshakeUnavailable)
        }
        if binding != nil, phase != .held { _ = validateBackend() }
        if !stderrFinished { consumeStderr() }
        // Never dispatch provider bytes before the fixed bootstrap has been consumed.
        guard binding != nil || phase == .held else { return }
        if !stdoutFinished { consumeStdout() }
        if stdoutFinished && stderrFinished { monitoringTask?.cancel() }
    }

    private func consumeStderr() {
        switch stderr.readNext() {
        case .waiting:
            break
        case .receipt(let receipt):
            guard phase == .awaitingBootstrap, let supervisor else {
                hold(.bootstrapUnavailable)
                break
            }
            do {
                let binding = try receipt.bind(
                    expectedNonce: nonce, expectedSupervisor: supervisor, executableURL: executableURL,
                    executableIdentity: executableIdentity, workingDirectory: workingDirectory
                )
                self.binding = binding
                backendIdentity = binding.receipt.backend
                let source = DispatchSource.makeProcessSource(
                    identifier: binding.receipt.backend.pid, eventMask: .exit, queue: .main
                )
                let launchID = self.launchID
                source.setEventHandler { [weak self] in
                    Task { @MainActor in
                        guard let self, self.launchID == launchID else { return }
                        self.holdForBackendLoss()
                    }
                }
                backendExitSource = source
                source.resume()
                try binding.revalidate()
                phase = .awaitingProvider
                deadline = .now.advanced(by: .seconds(30))
            } catch {
                hold(.bootstrapUnavailable)
            }
        case .providerStderr(let bytes):
            if phase != .held { outputSink?("stderr", bytes, launchID) }
        case .endOfFile:
            stderrEOF = true
            stderrFinished = true
            hold(phase == .awaitingProvider ? .providerHandshakeUnavailable : .streamEnded)
        case .failed(let error):
            stderrFinished = true
            hold(binding == nil ? .bootstrapUnavailable : .stderrReadFailed(error))
        }
    }

    private func consumeStdout() {
        switch stdout.readNext() {
        case .waiting:
            break
        case .bytes(let bytes):
            if phase != .held { outputSink?("stdout", bytes, launchID) }
        case .endOfFile:
            stdoutEOF = true
            stdoutFinished = true
            hold(phase == .awaitingProvider ? .providerHandshakeUnavailable : .streamEnded)
        case .failed(let error):
            stdoutFinished = true
            hold(.stdoutReadFailed(error))
        case .closed:
            stdoutFinished = true
            hold(.abandoned)
        }
    }

    @discardableResult
    private func validateBackend() -> Bool {
        guard let binding else { return false }
        do {
            try binding.revalidate()
            return true
        } catch {
            holdForBackendLoss()
            return false
        }
    }

    private func holdForBackendLoss() {
        hold(phase == .bound ? .backendUnavailable : .providerHandshakeUnavailable)
    }

    private func hold(_ reason: AgentSessionManagedLifetimeHold) {
        guard phase != .held else { return }
        phase = .held
        holdReason = reason
        boundIdentity = nil
        backendExitSource?.cancel()
        heldSink?(reason, launchID)
    }
}
