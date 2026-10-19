import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

@main
struct ManagedProcessSupervisorFixture {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments.first == "--fixture-foreground-census" {
            let accepted = OwnedProcessSupervisor.foregroundGroupIsComplete(
                backend: AgentPIDProcessIdentity(pid: 12345, startSeconds: 98765, startMicroseconds: 4321),
                listing: ManagedProcessListingFixture.make(arguments[1])
            )
            try? FileHandle.standardOutput.write(contentsOf: Data(accepted ? "true".utf8 : "false".utf8))
            exit(0)
        }
        if arguments.count == 2, arguments.first == "--fixture-command-service" {
            do {
                let result = try await ManagedCommandServiceFixture.run(arguments[1])
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                exit(0)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
        }
        if arguments.count == 2, arguments.first == "--fixture-command-marker" {
            guard FileManager.default.createFile(atPath: arguments[1], contents: Data("executed".utf8)) else {
                exit(1)
            }
            exit(0)
        }
        if arguments.count == 2, arguments.first == "--fixture-copilot-startup" {
            do {
                let result = try await ManagedCopilotStartupFixture.run(arguments[1])
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                exit(0)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
        }
        if arguments.count == 2, arguments.first == "--fixture-copilot-peer" {
            do {
                try ManagedCopilotStartupFixture.peer(arguments[1])
                exit(0)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
        }
        if arguments.first == "--fixture-lifetime", arguments.count == 2 {
            do {
                let result = try await ManagedSessionLifetimeFixture.run(arguments[1])
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                exit(0)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
        }
        if arguments.first == "--fixture-run-launcher" {
            do {
                try runPreparedLaunch()
                exit(0)
            } catch { exit(1) }
        }
        if ["--fixture-prepare-managed", "--fixture-prepare-foreground"].contains(arguments.first),
           arguments.count == 4 {
            do {
                guard let nonce = UUID(uuidString: arguments[1]) else { exit(1) }
                let launcher = AgentSessionOwnedProcessLauncher(
                    supervisorExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0])
                )
                let prepare = arguments.first == "--fixture-prepare-foreground"
                    ? launcher.prepareForeground : launcher.prepareManaged
                let process = try prepare(
                    nonce, URL(fileURLWithPath: arguments[2]),
                    ["--fixture-child", "literal argument"], arguments[3], ["FIXTURE": "controlled"]
                )
                let result: [String: Any] = [
                    "executable": process.executableURL?.path ?? "",
                    "arguments": process.arguments ?? [],
                    "directory": process.currentDirectoryURL?.path ?? "",
                    "environment": process.environment ?? [:],
                    "running": process.isRunning,
                ]
                let data = try JSONSerialization.data(withJSONObject: result)
                try FileHandle.standardOutput.write(contentsOf: data)
                exit(0)
            } catch { exit(1) }
        }
        if arguments.first == "--fixture-live", arguments.count == 4,
           let pid = Int32(arguments[1]), let seconds = Int64(arguments[2]),
           let microseconds = Int64(arguments[3]) {
            let identity = AgentPIDProcessIdentity(
                pid: pid, startSeconds: seconds, startMicroseconds: microseconds
            )
            exit(AgentPIDProcessIdentity(pid: pid) == identity ? 0 : 1)
        }
        if arguments.first == "--fixture-child" {
            _ = Data("resumed\n".utf8).withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            _ = Data("child-started\n".utf8).withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            if arguments.contains("--hold") {
                while true { pause() }
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { exit(0) }
                if count < 0 {
                    if errno == EINTR { continue }
                    exit(1)
                }
                if arguments.contains("--echo-stderr") {
                    let written = bytes.withUnsafeBytes {
                        Darwin.write(STDERR_FILENO, $0.baseAddress, count)
                    }
                    if written != count { exit(1) }
                }
            }
        }
        do {
            guard let command = arguments.first,
                  let supervisor = try OwnedProcessSupervisor(
                    command: command, arguments: Array(arguments.dropFirst())
                  ) else { exit(64) }
            exit(try supervisor.run())
        } catch {
            exit(1)
        }
    }

    @MainActor private static func runPreparedLaunch() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let executableIdentity = try ShepherdHookExecutableIdentity.capture(path: executable.path)
        let nonce = UUID()
        let process = try AgentSessionOwnedProcessLauncher(supervisorExecutableURL: executable).prepareManaged(
            nonce: nonce, executableURL: executable, arguments: ["--fixture-child"],
            workingDirectory: "/tmp", environment: ["FIXTURE": "controlled"]
        )
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let reader = try ShepherdManagedBootstrapReader(takingOwnershipOf: error.fileHandleForReading)
        defer { try? reader.close() }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        guard let supervisor = AgentPIDProcessIdentity(pid: process.processIdentifier) else {
            throw POSIXError(.ESRCH)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            switch reader.readNext() {
            case .waiting:
                usleep(1_000)
            case .receipt(let receipt):
                let binding = try receipt.bind(
                    expectedNonce: nonce, expectedSupervisor: supervisor,
                    executableURL: executable, executableIdentity: executableIdentity,
                    workingDirectory: "/tmp"
                )
                let data = try JSONSerialization.data(withJSONObject: [
                    "owner": binding.receipt.owner.pid,
                    "supervisor": binding.receipt.supervisor.pid,
                    "backend": binding.receipt.backend.pid,
                ])
                try FileHandle.standardOutput.write(contentsOf: data)
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
                return
            default:
                throw POSIXError(.EPROTO)
            }
        }
        throw POSIXError(.ETIMEDOUT)
    }
}

// Data-only type seams for compiling the actual launcher without a GUI test host.
struct AgentSessionLaunchPlan {
    let provider: AgentSessionProviderFixture
    let executableURL: URL
    let arguments: [String]
}

struct AgentSessionProviderFixture {
    let displayName: String
}

enum AgentSessionBridgeError: Error {
    case providerNotReady(String)
}
