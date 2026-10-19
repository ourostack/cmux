import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation
import Testing

@Suite struct ShepherdManagedBackendBindingTests {
    @Test func bindsTheRealChildRatherThanItsOwnedSupervisor() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        let binding = try fixture.bind()
        #expect(binding.receipt.backend.pid == fixture.backend.pid)
        #expect(binding.receipt.backend.pid != fixture.supervisor.pid)
        try binding.revalidate()
    }

    @Test func suspendedChildrenRemainObservableWithoutResumingThem() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        #expect(Darwin.kill(fixture.backend.pid, SIGSTOP) == 0)
        let binding = try fixture.bind()
        try binding.revalidate()
        #expect(Darwin.kill(fixture.backend.pid, SIGCONT) == 0)
    }

    @Test func aDifferentLaunchNonceNeverBinds() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        #expect(throws: ShepherdManagedBootstrapError.nonceMismatch) {
            try fixture.bind(nonce: UUID())
        }
    }

    @Test func claimedOwnerMustBeTheCurrentHostGeneration() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        for owner in [fixture.supervisor, staleBirth(fixture.owner)] {
            let receipt = try fixture.receipt(owner: owner)
            #expect(throws: ShepherdManagedBootstrapError.ownerMismatch) {
                try fixture.bind(receipt: receipt)
            }
        }
    }

    @Test func theOwnedSupervisorBirthCannotBeSubstituted() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        #expect(throws: ShepherdManagedBootstrapError.supervisorMismatch) {
            try fixture.bind(supervisor: staleBirth(fixture.supervisor))
        }
        #expect(throws: ShepherdManagedBootstrapError.supervisorMismatch) {
            try fixture.bind(receipt: fixture.receipt(supervisor: staleBirth(fixture.supervisor)))
        }
    }

    @Test func backendBirthAndActualParentMustBothMatch() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        for backend in [staleBirth(fixture.backend), fixture.supervisor, fixture.owner] {
            #expect(throws: ShepherdManagedBootstrapError.backendMismatch) {
                try fixture.bind(receipt: fixture.receipt(backend: backend))
            }
        }
    }

    @Test func aLiveChildFromAnotherOwnedLaunchIsNotOurBackend() async throws {
        let first = try await BootstrapProcessFixture.launch()
        defer { first.finish() }
        let second = try await BootstrapProcessFixture.launch()
        defer { second.finish() }
        #expect(throws: ShepherdManagedBootstrapError.backendMismatch) {
            try first.bind(receipt: first.receipt(backend: second.backend))
        }
    }

    @Test func executablePathAndFileGenerationMustMatchTheLaunchPlan() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        let wrongURL = URL(fileURLWithPath: "/bin/sh")
        let wrongIdentity = try ShepherdHookExecutableIdentity.capture(path: wrongURL.path)
        #expect(throws: ShepherdManagedBootstrapError.executableMismatch) {
            try fixture.bind(executableURL: wrongURL)
        }
        #expect(throws: ShepherdManagedBootstrapError.executableMismatch) {
            try fixture.bind(executableIdentity: wrongIdentity)
        }
    }

    @Test func canonicalWorkingDirectoryMustMatchTheActualBackend() async throws {
        let fixture = try await BootstrapProcessFixture.launch()
        defer { fixture.finish() }
        #expect(throws: ShepherdManagedBootstrapError.launchScopeMismatch) {
            try fixture.bind(directory: "/")
        }
        try fixture.bind(directory: "/tmp").revalidate()
    }

    @Test func backendExitInvalidatesBindingEvenBeforeSupervisorCleanup() async throws {
        let fixture = try await BootstrapProcessFixture.launch(holdAfterChildExit: true)
        defer { fixture.finish() }
        let binding = try fixture.bind()
        #expect(Darwin.kill(fixture.backend.pid, SIGTERM) == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while AgentPIDProcessIdentity.processSnapshot(pid: fixture.backend.pid) != nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(AgentPIDProcessIdentity.processSnapshot(pid: fixture.backend.pid) == nil)
        #expect(AgentPIDProcessIdentity.processSnapshot(pid: fixture.supervisor.pid)?.identity == fixture.supervisor)
        #expect(throws: ShepherdManagedBootstrapError.backendMismatch) {
            try binding.revalidate()
        }
    }
}

private func staleBirth(_ identity: AgentPIDProcessIdentity) -> AgentPIDProcessIdentity {
    AgentPIDProcessIdentity(
        pid: identity.pid, startSeconds: identity.startSeconds + 1,
        startMicroseconds: identity.startMicroseconds
    )
}

private struct BootstrapProcessFixture {
    let process: Process
    let input: Pipe
    let output: Pipe
    let owner: AgentPIDProcessIdentity
    let supervisor: AgentPIDProcessIdentity
    let backend: AgentPIDProcessIdentity
    let nonce = UUID()
    let executableURL = URL(fileURLWithPath: "/bin/cat")
    let executableIdentity: ShepherdHookExecutableIdentity

    static func launch(holdAfterChildExit: Bool = false) async throws -> Self {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // No coding provider or app: two controlled, private pipe fixtures.
        process.arguments = ["-c", "/bin/cat <&0 >/dev/null & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""
            + (holdAfterChildExit ? "; read finish" : "")]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let record = output.fileHandleForReading.availableData
            let child = try #require(Int32(String(decoding: record, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ShepherdHookExecutableIdentity.kernelExecutablePath(pid: child) != "/bin/cat",
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            return try Self(
                process: process, input: input, output: output,
                owner: #require(AgentPIDProcessIdentity(pid: getpid())),
                supervisor: #require(AgentPIDProcessIdentity(pid: process.processIdentifier)),
                backend: #require(AgentPIDProcessIdentity(pid: child)),
                executableIdentity: ShepherdHookExecutableIdentity.capture(path: "/bin/cat")
            )
        } catch {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            throw error
        }
    }

    func receipt(
        owner: AgentPIDProcessIdentity? = nil,
        supervisor: AgentPIDProcessIdentity? = nil,
        backend: AgentPIDProcessIdentity? = nil
    ) throws -> ShepherdManagedBackendLaunchReceipt {
        try ShepherdManagedBackendLaunchReceipt(
            nonce: nonce, owner: owner ?? self.owner,
            supervisor: supervisor ?? self.supervisor, backend: backend ?? self.backend
        )
    }

    func bind(
        receipt: ShepherdManagedBackendLaunchReceipt? = nil, nonce: UUID? = nil,
        supervisor: AgentPIDProcessIdentity? = nil, executableURL: URL? = nil,
        executableIdentity: ShepherdHookExecutableIdentity? = nil, directory: String = "/private/tmp"
    ) throws -> ShepherdManagedBackendBinding {
        try (receipt ?? self.receipt()).bind(
            expectedNonce: nonce ?? self.nonce, expectedSupervisor: supervisor ?? self.supervisor,
            executableURL: executableURL ?? self.executableURL,
            executableIdentity: executableIdentity ?? self.executableIdentity,
            workingDirectory: directory
        )
    }

    func finish() {
        if AgentPIDProcessIdentity(pid: backend.pid) == backend {
            _ = Darwin.kill(backend.pid, SIGCONT)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
