import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

@MainActor
enum ManagedSessionLifetimeFixture {
    struct Launch {
        let process: Process
        let input: Pipe
        let session: AgentSessionManagedSession
    }

    static func launch(managed: Bool = true) throws -> Launch {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let nonce = UUID()
        let process = try AgentSessionOwnedProcessLauncher(supervisorExecutableURL: executable).prepareManaged(
            nonce: nonce, executableURL: executable, arguments: ["--fixture-child"],
            workingDirectory: "/tmp", environment: [:]
        )
        if !managed {
            process.arguments = ["__owned-process-supervisor", executable.path, "--fixture-child"]
        }
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let session = try AgentSessionManagedSession(
            nonce: nonce, hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(),
            surfaceGeneration: 1, provider: .claude,
            executableURL: executable,
            executableIdentity: ShepherdHookExecutableIdentity.capture(path: executable.path),
            executableSHA256: String(repeating: "a", count: 64),
            profileSHA256: String(repeating: "b", count: 64),
            workingDirectory: "/tmp",
            stdout: output.fileHandleForReading, stderr: error.fileHandleForReading
        )
        try process.run()
        // Foundation closes these parent-side child endpoints when launching a Pipe.
        guard let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) else {
            throw POSIXError(.ESRCH)
        }
        try session.attach(supervisor: supervisor)
        return Launch(process: process, input: input, session: session)
    }

    static func finish(_ launch: Launch) {
        try? launch.session.abandon()
        try? launch.input.fileHandleForWriting.close()
        if launch.process.isRunning { launch.process.terminate() }
        launch.process.waitUntilExit()
    }

    static func wait(_ predicate: () -> Bool, seconds: Double = 3) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func phase(_ session: AgentSessionManagedSession) -> String {
        switch session.phase {
        case .awaitingBootstrap: "awaitingBootstrap"
        case .awaitingProvider: "awaitingProvider"
        case .bound: "bound"
        case .held: "held"
        }
    }

    static func run(_ scenario: String) async throws -> [String: Any] {
        if scenario == "read-results" {
            let pipe = Pipe()
            let reader = try AgentSessionManagedOutputReader(takingOwnershipOf: pipe.fileHandleForReading)
            let first = reader.readNext()
            try pipe.fileHandleForWriting.close()
            let second = reader.readNext()
            let other = Pipe()
            let closed = try AgentSessionManagedOutputReader(takingOwnershipOf: other.fileHandleForReading)
            try closed.close()
            let invalid = Pipe()
            // A real FIFO descriptor with no read permission produces EBADF, not EOF.
            let failed = try AgentSessionManagedOutputReader(takingOwnershipOf: invalid.fileHandleForWriting)
            defer {
                try? reader.close(); try? other.fileHandleForWriting.close()
                try? failed.close(); try? invalid.fileHandleForReading.close()
            }
            let failure = failed.readNext()
            return [
                "beforeClose": label(first), "afterWriterClose": label(second),
                "afterReaderClose": label(closed.readNext()),
                "closedIsDrain": closed.readNext() == .endOfFile,
                "readFailure": label(failure), "stickyFailure": failed.readNext() == failure,
            ]
        }
        let launch = try launch(managed: scenario != "bootstrap-timeout")
        defer { finish(launch) }
        let session = launch.session
        if scenario == "bootstrap-timeout" {
            try await wait({ phase(session) == "held" }, seconds: 7)
            return [
                "phase": phase(session),
                "reason": session.holdReason.map { String(describing: $0) } ?? "",
                "drained": session.hasActuallyDrainedStreams,
                "identity": session.identity != nil,
            ]
        }
        if scenario == "early-handshake" {
            let accepted = session.acceptProviderHandshake(sessionID: "premature", launchID: session.launchID)
            return ["accepted": accepted, "phase": phase(session), "identity": session.identity != nil]
        }
        try await wait { phase(session) == "awaitingProvider" }
        switch scenario {
        case "handshake":
            let before = phase(session), identityBefore = session.identity != nil
            let accepted = session.acceptProviderHandshake(
                sessionID: "actual-provider-session", launchID: session.launchID
            )
            return [
                "afterReceipt": before, "identityBeforeHandshake": identityBefore,
                "accepted": accepted, "providerSessionID": session.identity?.providerSessionID ?? "",
                "backend": session.identity?.backendPID ?? -1,
                "receiptBackend": session.backendIdentity?.pid ?? -2,
            ]
        case "stale":
            let replacement = try self.launch()
            defer { finish(replacement) }
            try await wait { phase(replacement.session) == "awaitingProvider" }
            let acceptedOld = replacement.session.acceptProviderHandshake(
                sessionID: "old-session", launchID: session.launchID
            )
            let afterOld = phase(replacement.session)
            let acceptedCurrent = replacement.session.acceptProviderHandshake(
                sessionID: "current-session", launchID: replacement.session.launchID
            )
            return [
                "acceptedOld": acceptedOld, "afterOld": afterOld, "acceptedCurrent": acceptedCurrent,
                "providerSessionID": replacement.session.identity?.providerSessionID ?? "",
            ]
        case "conflict":
            let first = session.acceptProviderHandshake(sessionID: "first", launchID: session.launchID)
            let conflict = session.acceptProviderHandshake(sessionID: "second", launchID: session.launchID)
            return [
                "acceptedFirst": first, "acceptedConflict": conflict,
                "phase": phase(session), "identityAfterConflict": session.identity != nil,
            ]
        case "invalid-handshake":
            let accepted = session.acceptProviderHandshake(sessionID: "foreign\nsession", launchID: session.launchID)
            return ["accepted": accepted, "phase": phase(session), "identity": session.identity != nil]
        case "pre-handshake-exit":
            guard let backend = session.backendIdentity, kill(backend.pid, SIGKILL) == 0 else {
                throw POSIXError(.ESRCH)
            }
            try await wait { phase(session) == "held" }
            return [
                "phase": phase(session),
                "reason": session.holdReason.map { String(describing: $0) } ?? "",
                "acceptedLate": session.acceptProviderHandshake(sessionID: "late", launchID: session.launchID),
            ]
        case "backend-exit":
            guard let backend = session.backendIdentity else { throw POSIXError(.ESRCH) }
            let bound = session.acceptProviderHandshake(sessionID: "actual", launchID: session.launchID)
            // Keep the real supervisor observable while its backend dies.
            guard kill(launch.process.processIdentifier, SIGSTOP) == 0 else { throw POSIXError(.ESRCH) }
            defer { kill(launch.process.processIdentifier, SIGCONT) }
            guard kill(backend.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            try await wait { phase(session) == "held" }
            return [
                "boundBeforeExit": bound, "supervisorStillAlive": launch.process.isRunning,
                "phase": phase(session), "identityAfterExit": session.identity != nil,
                "drained": session.hasActuallyDrainedStreams,
            ]
        case "abandon":
            try session.abandon()
            return [
                "phase": phase(session),
                "acceptedLate": session.acceptProviderHandshake(sessionID: "late", launchID: session.launchID),
                "drained": session.hasActuallyDrainedStreams,
            ]
        case "drain":
            _ = session.acceptProviderHandshake(sessionID: "actual", launchID: session.launchID)
            try launch.input.fileHandleForWriting.close()
            try await wait { session.hasActuallyDrainedStreams }
            return [
                "phase": phase(session), "drained": session.hasActuallyDrainedStreams,
                "identityAfterExit": session.identity != nil,
            ]
        case "timeout":
            let before = phase(session)
            try await wait({ phase(session) == "held" }, seconds: 32)
            return [
                "before": before, "phase": phase(session),
                "reason": session.holdReason.map { String(describing: $0) } ?? "",
                "acceptedLate": session.acceptProviderHandshake(sessionID: "late", launchID: session.launchID),
            ]
        default:
            throw POSIXError(.EINVAL)
        }
    }

    static func label(_ value: AgentSessionManagedOutputRead) -> String {
        switch value {
        case .waiting: "waiting"
        case .bytes: "bytes"
        case .endOfFile: "endOfFile"
        case .failed(let code): "errno:\(code)"
        case .closed: "closed"
        }
    }
}
