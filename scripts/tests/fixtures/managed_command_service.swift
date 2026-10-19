import CmuxControlSocket
import Darwin
import Foundation

@MainActor
enum ManagedCommandServiceFixture {
    private final class Owner {
        weak var service: AgentSessionManagedCommandService?
        var live = true
    }

    static func run(_ scenario: String) async throws -> [String: Any] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let owner = Owner()
        let operationID = UUID()
        let service = AgentSessionManagedCommandService(
            launcher: AgentSessionOwnedProcessLauncher(
                supervisorExecutableURL: scenario == "missing-receipt"
                    ? URL(fileURLWithPath: "/usr/bin/true") : executable
            ),
            workingDirectory: "/tmp", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            validateOwner: {
                if scenario == "invalidate-before-ready",
                   owner.service?.stages(for: operationID).contains("observing") == true {
                    // Give a wrongly resumed child time to expose its real side effect.
                    usleep(250_000)
                    return false
                }
                return owner.live
            }
        )
        owner.service = service
        if scenario == "invalid-commands" {
            let invalid: [(String, [String])] = [
                ("relative", []), ("/bin/sh\0", []), ("/bin/sh", ["bad\0arg"]),
                ("/bin/sh", Array(repeating: "arg", count: 257)),
                ("/bin/sh", [String(repeating: "x", count: 65_536)]),
            ]
            return ["rejected": invalid.map {
                AgentSessionManagedCommandService.Command(program: $0.0, arguments: $0.1) == nil
            }, "outstanding": service.outstandingWorkCount]
        }
        let marker = executable.deletingLastPathComponent().appendingPathComponent(operationID.uuidString)
        let program: String
        let arguments: [String]
        switch scenario {
        case "fast", "replay", "sequential", "missing-receipt":
            program = executable.path
            arguments = ["--fixture-child"]
        case "invalidate-before-ready":
            program = executable.path
            arguments = ["--fixture-command-marker", marker.path]
        case "delayed-exit":
            program = "/bin/sh"
            arguments = ["-c", "exec 1>&- 2>&-; sleep 0.2; exit 0"]
        case "late-stderr":
            program = "/bin/sh"
            arguments = ["-c", "printf first; exec 1>&-; sleep 0.2; printf late >&2"]
        case "nonzero":
            program = "/bin/sh"
            arguments = ["-c", "printf failure >&2; exit 7"]
        case "reserved":
            program = "/bin/sh"
            arguments = ["-c", "exit 254"]
        case "survivor":
            program = "/bin/sh"
            arguments = ["-c", "sleep 30 </dev/null >/dev/null 2>/dev/null & sleep 0.1; exit 0"]
        case "output-limit":
            program = "/bin/sh"
            arguments = ["-c", "head -c 262145 /dev/zero"]
        case "cancel", "owner-loss", "overlap", "timeout":
            program = "/bin/sh"
            arguments = ["-c", "echo active; sleep 120"]
        case "launch-failure":
            program = "/no-such-managed-foreground-fixture"
            arguments = []
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let command = AgentSessionManagedCommandService.Command(program: program, arguments: arguments) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let started = ContinuousClock.now
        let operation = Task { await service.execute(command, operationID: operationID) }
        var overlapHeld = false
        if ["cancel", "owner-loss", "overlap"].contains(scenario) {
            try await ManagedSessionLifetimeFixture.wait {
                service.stages(for: operationID).contains("ready")
            }
            if scenario == "cancel" {
                operation.cancel()
            } else if scenario == "owner-loss" {
                owner.live = false
            } else {
                let overlapping = await service.execute(command, operationID: UUID())
                if case .held(.registryConflict) = overlapping { overlapHeld = true }
            }
        }
        let outcome = await operation.value
        var result: [String: Any] = [
            "outstanding": service.outstandingWorkCount,
            "markerExists": FileManager.default.fileExists(atPath: marker.path),
            "overlapHeld": overlapHeld,
            "durationMilliseconds": started.duration(to: .now).components.seconds * 1000
                + started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000,
        ]
        switch outcome {
        case .held(let reason):
            result["outcome"] = "held"
            result["reason"] = reason.rawValue
            result["stages"] = service.stages(for: operationID)
        case .completed(let completion):
            result["outcome"] = "completed"
            result["status"] = completion.status
            result["stdout"] = String(decoding: completion.stdout, as: UTF8.self)
            result["stderr"] = String(decoding: completion.stderr, as: UTF8.self)
            result["stages"] = completion.stages
            result["owner"] = completion.receipt.owner.pid
            result["supervisor"] = completion.receipt.supervisor.pid
            result["backend"] = completion.receipt.backend.pid
        }
        if scenario == "replay" {
            let replay = await service.execute(command, operationID: operationID)
            let replacement = await service.execute(command, operationID: UUID())
            if case .held(.registryConflict) = replay { result["replayHeld"] = true }
            if case .held(.registryConflict) = replacement { result["replacementHeld"] = true }
        }
        if scenario == "sequential" {
            let second = await service.execute(command, operationID: UUID())
            if case .completed(let completion) = second {
                result["secondCompleted"] = completion.status == 0
                    && String(decoding: completion.stdout, as: UTF8.self) == "resumed\n"
                    && completion.stages.last == "drained"
            }
            result["outstandingAfterSecond"] = service.outstandingWorkCount
        }
        return result
    }
}
