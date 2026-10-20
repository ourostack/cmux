import CmuxControlSocket
import CmuxFoundation
import CryptoKit
import Darwin
import Foundation

/// Owned source-candidate composition, never a runtime/profile qualification.
@MainActor
final class AgentSessionManagedCopilotLaunch {
    enum CloseError: Error {
        case supervisorExitUnobserved(
            expected: AgentPIDProcessIdentity?, observed: AgentPIDProcessIdentity?, processReportsRunning: Bool
        )
        case supervisorCleanupUnverified(expected: AgentPIDProcessIdentity?, terminationStatus: Int32)
    }

    struct Scope: Equatable {
        let hostInstance: UUID
        let workspaceID: UUID
        let surfaceID: UUID
        let generation: UInt64
    }

    /// A native object capability, never decoded from bridge or provider data.
    @MainActor final class NativeCodingOwner {
        static let executionDisclosure =
            "General-purpose foreground coding commands run as your OS account, with no sandbox " +
            "and no per-call SDK permission prompt. They can access or change files and use the network " +
            "where your account has access. The project folder is a working directory, not confinement."
        private static let hostInstance = UUID()
        let scope: Scope
        let projectMandate = UUID()
        let workingDirectory: String
        let rendererID: String
        private let host: AgentPIDProcessIdentity
        private weak var owningStore: AnyObject?
        private let isCurrentOwner: @MainActor () -> Bool
        private weak var lifetime: AgentSessionManagedSession?
        private var consumed = false
        private var revoked = false
        private var revocationSink: (() -> Void)?

        init?(
            newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
            owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool
        ) {
            guard ["react", "solid"].contains(rendererID),
                  let host = AgentPIDProcessIdentity(pid: getpid()),
                  let directory = try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory),
                  isCurrentOwner() else { return nil }
            self.scope = Scope(
                hostInstance: Self.hostInstance, workspaceID: workspaceID, surfaceID: newPanelID, generation: 1
            )
            self.workingDirectory = directory
            self.rendererID = rendererID
            self.host = host
            self.owningStore = owningStore
            self.isCurrentOwner = isCurrentOwner
        }

        func consume(
            for store: AnyObject, scope: Scope, workingDirectory: String, projectMandate: UUID
        ) -> Bool {
            guard !consumed, owningStore === store, self.scope == scope,
                  self.projectMandate == projectMandate,
                  (try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory)) == self.workingDirectory,
                  isCurrent else {
                revoke()
                return false
            }
            consumed = true
            return true
        }

        func installRevocationSink(for store: AnyObject, _ sink: @escaping () -> Void) -> Bool {
            guard consumed, owningStore === store, revocationSink == nil, isCurrent else { return false }
            revocationSink = sink
            return true
        }

        func bind(to lifetime: AgentSessionManagedSession) -> Bool {
            guard consumed, self.lifetime == nil, isCurrent,
                  lifetime.ownsWorkingDirectory(workingDirectory) else {
                revoke()
                return false
            }
            self.lifetime = lifetime
            return true
        }

        var isCurrent: Bool {
            !revoked && owningStore != nil && AgentPIDProcessIdentity(pid: getpid()) == host && isCurrentOwner()
        }

        func authorizes(_ lifetime: AgentSessionManagedSession) -> Bool {
            consumed && self.lifetime === lifetime && isCurrent
        }

        func revoke() {
            guard !revoked else { return }
            revoked = true
            revocationSink?()
        }
    }

    static let arguments = ["--headless", "--no-auto-update", "--stdio", "--allow-all"]
    let lifetime: AgentSessionManagedSession
    let adapter: CopilotManagedSession
    let codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority?
    let executableSHA256: String
    let profileSHA256: String
    let profileManifest: Data
    let workingDirectory: String
    private let process: Process
    private let executableURL: URL
    private let executableIdentity: ShepherdHookExecutableIdentity
    private var supervisor: AgentPIDProcessIdentity?
    private var launched = false
    private var started = false
    private var closed = false
    private var closeTask: Task<Void, any Error>?

    var processIdentifier: Int32 { process.processIdentifier }
    var backendArguments: [String] { Array((process.arguments ?? []).dropFirst(3)) }

    static func prepare(
        scope: Scope, executableURL: URL, workingDirectory: String, codingProjectMandate: UUID?,
        nativeCodingOwner: NativeCodingOwner? = nil,
        launcher: AgentSessionOwnedProcessLauncher = .init()
    ) async throws -> AgentSessionManagedCopilotLaunch {
        guard scope.generation > 0, executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              workingDirectory.hasPrefix("/"), !workingDirectory.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let verified = try await Task.detached {
            let path = try canonicalPath(executableURL.path)
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
            let digest = try identity.hash(fileDescriptor: descriptor)
            guard digest.isNativeExecutable, try ShepherdHookExecutableIdentity.capture(path: path) == identity else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (path, identity, digest.sha256)
        }.value
        try Task.checkCancellation()
        let directory = try canonicalPath(workingDirectory)
        if let nativeCodingOwner {
            guard nativeCodingOwner.scope == scope,
                  nativeCodingOwner.projectMandate == codingProjectMandate,
                  nativeCodingOwner.workingDirectory == directory,
                  nativeCodingOwner.isCurrent else { throw CancellationError() }
        }
        let nativeTool = codingProjectMandate != nil
        let profile: [String: Any] = [
            "version": 1, "provider": "copilot", "cliVersion": "1.0.98", "sdkVersion": "1.0.22",
            "sdkCommit": "ffd25c775742f73e13a492093be0287d7885123f",
            "arguments": arguments,
            "create": CopilotManagedConfiguration.createParameters(
                sessionID: "<native-session>", workingDirectory: "<native-project>", nativeForegroundTool: nativeTool
            ),
            "options": CopilotManagedConfiguration.optionParameters(
                sessionID: "<native-session>", nativeForegroundTool: nativeTool
            ),
            "workContract": "root-external-native-command-ack-v1",
            "commandAuthority": nativeTool ? "general-purpose-foreground-os-account" : "none",
            "environment": ["HOME": "<native-home>", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
        ]
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys, .withoutEscapingSlashes])
        let profileSHA256 = SHA256.hash(data: profileData).map { String(format: "%02x", $0) }.joined()
        let environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ]
        let nonce = UUID()
        let canonicalExecutable = URL(fileURLWithPath: verified.0)
        let process = try launcher.prepareManaged(
            nonce: nonce, executableURL: canonicalExecutable, arguments: arguments,
            workingDirectory: directory, environment: environment
        )
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let lifetime = try AgentSessionManagedSession(
            nonce: nonce, hostInstance: scope.hostInstance, workspaceID: scope.workspaceID, surfaceID: scope.surfaceID,
            surfaceGeneration: scope.generation, provider: .copilot, executableURL: canonicalExecutable,
            executableIdentity: verified.1, executableSHA256: verified.2, profileSHA256: profileSHA256,
            workingDirectory: directory, stdout: output.fileHandleForReading, stderr: error.fileHandleForReading
        )
        let authority: AgentSessionManagedCommandService.NativeCodingAuthority?
        if let nativeCodingOwner, !nativeCodingOwner.bind(to: lifetime) {
            throw CocoaError(.fileReadNoPermission)
        }
        if let codingProjectMandate {
            let validateNativeOwner: @MainActor () -> Bool
            if let nativeCodingOwner {
                validateNativeOwner = { [weak nativeCodingOwner, weak lifetime] in
                    guard let nativeCodingOwner, let lifetime else { return false }
                    return nativeCodingOwner.authorizes(lifetime)
                }
            } else {
                validateNativeOwner = { true }
            }
            guard let granted = AgentSessionManagedCommandService.NativeCodingAuthority(
                explicitNativeCodingOptInFor: lifetime, projectMandate: codingProjectMandate, workingDirectory: directory,
                launcher: launcher, environment: environment,
                validateNativeOwner: validateNativeOwner
            ) else { throw CocoaError(.fileReadNoPermission) }
            authority = granted
        } else {
            authority = nil
        }
        let adapter = try CopilotManagedSession(
            lifetime: lifetime, takingOwnershipOf: input.fileHandleForWriting, workingDirectory: directory,
            codingAuthority: authority
        )
        return AgentSessionManagedCopilotLaunch(
            process: process, lifetime: lifetime, adapter: adapter, codingAuthority: authority,
            executableURL: canonicalExecutable, executableIdentity: verified.1,
            executableSHA256: verified.2, profileSHA256: profileSHA256, profileManifest: profileData, workingDirectory: directory
        )
    }

    private init(
        process: Process, lifetime: AgentSessionManagedSession, adapter: CopilotManagedSession,
        codingAuthority: AgentSessionManagedCommandService.NativeCodingAuthority?,
        executableURL: URL, executableIdentity: ShepherdHookExecutableIdentity,
        executableSHA256: String, profileSHA256: String, profileManifest: Data, workingDirectory: String
    ) {
        self.process = process
        self.lifetime = lifetime
        self.adapter = adapter
        self.codingAuthority = codingAuthority
        self.executableURL = executableURL
        self.executableIdentity = executableIdentity
        self.executableSHA256 = executableSHA256
        self.profileSHA256 = profileSHA256
        self.profileManifest = profileManifest
        self.workingDirectory = workingDirectory
    }

    nonisolated private static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func launchBackend() throws {
        guard !launched, !closed else {
            codingAuthority?.revoke()
            try lifetime.abandon()
            throw CocoaError(.fileReadCorruptFile)
        }
        guard try ShepherdHookExecutableIdentity.capture(path: executableURL.path) == executableIdentity else {
            throw CocoaError(.fileReadCorruptFile)
        }
        launched = true
        try process.run()
        started = true
        guard let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) else {
            throw POSIXError(.ESRCH)
        }
        self.supervisor = supervisor
        try lifetime.attach(supervisor: supervisor)
    }

    func beginClose() -> Task<Void, any Error> {
        if let closeTask { return closeTask }
        closed = true
        codingAuthority?.revoke()
        let initialFailure: (any Error)?
        do {
            try lifetime.abandon()
            initialFailure = nil
        } catch {
            initialFailure = error
        }
        let task = Task { try await self.finishClose(initialFailure: initialFailure) }
        closeTask = task
        return task
    }

    func close() async throws {
        try await beginClose().value
    }

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
                        expected: supervisor,
                        observed: supervisor.flatMap { AgentPIDProcessIdentity(pid: $0.pid) },
                        processReportsRunning: process.isRunning
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if failure == nil { failure = error }
        }
        if started, !process.isRunning, process.terminationReason != .exit, failure == nil {
            failure = CloseError.supervisorCleanupUnverified(
                expected: supervisor, terminationStatus: process.terminationStatus
            )
        }
        if let failure { throw failure }
    }
}
