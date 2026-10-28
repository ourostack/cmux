import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

@MainActor
final class AgentSessionManagedCodexLaunch {
    typealias CloseError = AgentSessionManagedCopilotLaunch.CloseError
    let lifetime: AgentSessionManagedSession
    let adapter: CodexManagedSession
    let codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority
    let profileManifest: Data
    let executableSHA256: String
    let profileSHA256 = CodexManagedStartup.profileSHA256
    let workingDirectory: String
    var providerAdapter: any AgentSessionManagedProviderAdapter { adapter }
    private let process: Process
    private let executableURL: URL
    private let executableIdentity: ShepherdHookExecutableIdentity
    private let nativeOwner: AgentSessionManagedNativeOwner
    private var supervisor: AgentPIDProcessIdentity?
    private var launched = false
    private var started = false
    private var closed = false
    private var closeTask: Task<Void, any Error>?
    var processIdentifier: Int32 { process.processIdentifier }
    var backendArguments: [String] { Array((process.arguments ?? []).dropFirst(3)) }

    static func prepare(
        scope: AgentSessionManagedNativeOwner.Scope, executableURL: URL, workingDirectory: String,
        nativeOwner: AgentSessionManagedNativeOwner,
        launcher: AgentSessionOwnedProcessLauncher = .init()
    ) async throws -> AgentSessionManagedCodexLaunch {
        let directory = try AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory)
        guard scope.generation > 0, executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              nativeOwner.provider == .codex, nativeOwner.scope == scope,
              nativeOwner.workingDirectory == directory, nativeOwner.isCurrent else {
            throw CocoaError(.fileReadNoPermission)
        }
        let verified = try await Task.detached {
            let path = try AgentSessionManagedCopilotLaunch.canonicalPath(executableURL.path)
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
            let digest = try identity.hash(fileDescriptor: descriptor)
            guard digest.isNativeExecutable, try ShepherdHookExecutableIdentity.capture(path: path) == identity else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (URL(fileURLWithPath: path), identity, digest.sha256)
        }.value
        try Task.checkCancellation()
        guard nativeOwner.isCurrent else { throw CancellationError() }
        let manifest = try CodexManagedStartup.sourceManifest()
        let environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ]
        let nonce = UUID()
        let process = try launcher.prepareManaged(
            nonce: nonce, executableURL: verified.0,
            arguments: ["--private-stdio", "--boot-nonce", nonce.uuidString.lowercased(), "--cwd", directory],
            workingDirectory: directory, environment: environment)
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let lifetime = try AgentSessionManagedSession(
            nonce: nonce, hostInstance: scope.hostInstance, workspaceID: scope.workspaceID, surfaceID: scope.surfaceID,
            surfaceGeneration: scope.generation, provider: .codex, executableURL: verified.0,
            executableIdentity: verified.1, executableSHA256: verified.2,
            profileSHA256: CodexManagedStartup.profileSHA256, workingDirectory: directory,
            stdout: output.fileHandleForReading, stderr: error.fileHandleForReading)
        guard nativeOwner.bind(to: lifetime),
              let authority = AgentSessionManagedCommandService.NativeCodingAuthority(
                explicitNativeCodingOptInFor: lifetime, projectMandate: nativeOwner.projectMandate,
                workingDirectory: directory, launcher: launcher, environment: environment,
                validateNativeOwner: { [weak nativeOwner, weak lifetime] in
                    guard let nativeOwner, let lifetime else { return false }
                    return nativeOwner.authorizes(lifetime)
                }
              ) else { throw CocoaError(.fileReadNoPermission) }
        do {
            let adapter = try CodexManagedSession(
                lifetime: lifetime, takingOwnershipOf: input.fileHandleForWriting,
                workingDirectory: directory, bootNonce: nonce, nativeOwner: nativeOwner,
                codingAuthority: authority)
            return AgentSessionManagedCodexLaunch(
                lifetime: lifetime, adapter: adapter, codingAuthority: authority,
                profileManifest: manifest, process: process, executableURL: verified.0,
                executableIdentity: verified.1, executableSHA256: verified.2,
                workingDirectory: directory, nativeOwner: nativeOwner)
        } catch {
            authority.revoke()
            nativeOwner.revoke()
            try lifetime.abandon()
            throw error
        }
    }

    private init(
        lifetime: AgentSessionManagedSession, adapter: CodexManagedSession,
        codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority,
        profileManifest: Data, process: Process, executableURL: URL,
        executableIdentity: ShepherdHookExecutableIdentity, executableSHA256: String,
        workingDirectory: String, nativeOwner: AgentSessionManagedNativeOwner
    ) {
        self.lifetime = lifetime
        self.adapter = adapter
        self.codingAuthority = codingAuthority
        self.profileManifest = profileManifest
        self.process = process
        self.executableURL = executableURL
        self.executableIdentity = executableIdentity
        self.executableSHA256 = executableSHA256
        self.workingDirectory = workingDirectory
        self.nativeOwner = nativeOwner
    }

    func launchBackend() throws {
        guard !launched, !closed, nativeOwner.authorizes(lifetime) else {
            codingAuthority.revoke()
            try lifetime.abandon()
            throw CocoaError(.fileReadNoPermission)
        }
        try nativeOwner.requireQualifiedProfile(executableSHA256: executableSHA256, profileSHA256: profileSHA256)
        guard try ShepherdHookExecutableIdentity.capture(path: executableURL.path) == executableIdentity else {
            throw CocoaError(.fileReadCorruptFile)
        }
        launched = true
        try process.run()
        started = true
        guard let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) else { throw POSIXError(.ESRCH) }
        self.supervisor = supervisor
        try lifetime.attach(supervisor: supervisor)
    }

    func beginClose() -> Task<Void, any Error> {
        if let closeTask { return closeTask }
        closed = true
        codingAuthority.revoke()
        var initialFailure: (any Error)?
        do { try lifetime.abandon() } catch { initialFailure = error }
        let task = Task { try await self.finishClose(initialFailure: initialFailure) }
        closeTask = task
        return task
    }

    func close() async throws { try await beginClose().value }

    private func finishClose(initialFailure: (any Error)?) async throws {
        var failure = initialFailure
        if process.isRunning, let supervisor, AgentPIDProcessIdentity(pid: supervisor.pid) == supervisor {
            process.terminate()
        }
        await adapter.waitForCommandSettlement()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else {
                    throw CloseError.supervisorExitUnobserved(
                        expected: supervisor, observed: supervisor.flatMap { AgentPIDProcessIdentity(pid: $0.pid) },
                        processReportsRunning: process.isRunning)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch { if failure == nil { failure = error } }
        if started, !process.isRunning, process.terminationReason != .exit, failure == nil {
            failure = CloseError.supervisorCleanupUnverified(expected: supervisor, terminationStatus: process.terminationStatus)
        }
        if codingAuthority.outstandingWorkCount != 0, failure == nil {
            failure = CloseError.commandWorkUnsettled(outstanding: codingAuthority.outstandingWorkCount)
        }
        if let failure { throw failure }
    }
}
