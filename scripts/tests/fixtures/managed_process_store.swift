import CmuxFoundation
import Darwin
import Foundation

@main
struct ManagedProcessStoreFixture {
    static let acceptedOwnerPrompt = "Owner input: \u{96EA} \u{1F408}"

    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if arguments.count == 2, arguments.first == "--fixture-store" {
                let result = try await run(arguments[1])
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
                return
            }
            if arguments == ["--headless", "--no-auto-update", "--stdio", "--allow-all"] {
                guard let scenario = try ManagedCopilotStartupFixture.configuration()["scenario"] else {
                    throw POSIXError(.EPROTO)
                }
                try Data("\(getpid())".utf8).write(
                    to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(".cmux-controlled-backend-pid")
                )
                try ManagedCopilotStartupFixture.peer(scenario)
                return
            }
            if arguments == ["--fixture-store-manual"] {
                var bytes = [UInt8](repeating: 0, count: 4096)
                var count: Int
                repeat { count = Darwin.read(STDIN_FILENO, &bytes, bytes.count) } while count < 0 && errno == EINTR
                guard count > 0 else { throw POSIXError(.EIO) }
                try Data(bytes.prefix(count)).write(
                    to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(".cmux-controlled-manual-input")
                )
                while true { pause() }
            }
            guard let command = arguments.first,
                  let supervisor = try OwnedProcessSupervisor(
                    command: command, arguments: Array(arguments.dropFirst())
                  ) else { throw POSIXError(.EINVAL) }
            exit(try supervisor.run())
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ scenario: String) async throws -> [String: Any] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-managed-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let peerScenario = scenario == "startup-held" ? "inherited-mcp"
            : scenario == "post-start-protocol-hold" ? "owner-configuration-changed" : "owner-early-root"
        try JSONSerialization.data(withJSONObject: ["scenario": peerScenario, "callbackFile": ""])
            .write(to: directory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        let store = AgentSessionProcessStore()
        var events: [[String: Any]] = []
        store.eventSink = { events.append($0) }
        let scope = AgentSessionManagedCopilotLaunch.Scope(
            hostInstance: UUID(), workspaceID: UUID(), surfaceID: UUID(), generation: 1
        )
        var duplicate: Task<String, Never>?
        var observedReservation = false
        store.activeProviderSink = { active in
            guard active, !observedReservation else { return }
            observedReservation = true
            if scenario == "cancel-preparation" { store.closeAll() }
            if scenario == "cancel-awaiting-preparation" {
                Task { @MainActor in store.closeAll() }
            }
            if scenario == "duplicate-preparation" {
                duplicate = Task { @MainActor in
                    do {
                        _ = try await store.startManagedCopilot(
                            scope: scope, executableURL: executable, workingDirectory: directory.path,
                            codingProjectMandate: nil, launcher: .init(supervisorExecutableURL: executable)
                        )
                        return ""
                    } catch {
                        return (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
                    }
                }
            }
        }
        var startError = ""
        var sessionID = ""
        var manualStartError = ""
        var manualSessionID = ""
        if scenario == "manual-first" {
            do {
                manualSessionID = try await store.start(
                    plan: .init(
                        provider: .claude, executableURL: executable,
                        arguments: ["--fixture-store-manual"], environment: [:]
                    ),
                    workingDirectory: directory.path, launcher: .init(supervisorExecutableURL: executable)
                ).sessionId
            } catch {
                manualStartError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
            }
        }
        do {
            sessionID = try await store.startManagedCopilot(
                scope: scope,
                executableURL: executable, workingDirectory: directory.path, codingProjectMandate: nil,
                launcher: .init(supervisorExecutableURL: executable)
            ).sessionId
        } catch {
            startError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
        }
        let active = store.hasActiveProviderSession
        let duplicateError = await duplicate?.value ?? ""
        var permissionRefused = false
        var subsequentInputRefused = false
        if scenario == "unsupported-permission", !sessionID.isEmpty {
            do {
                try await store.writeLine(sessionId: sessionID, permissionMode: .fullAccess, text: "not allowed")
            } catch { permissionRefused = true }
            do {
                try await store.writeLine(sessionId: sessionID, text: acceptedOwnerPrompt)
            } catch { subsequentInputRefused = true }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
            while ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        if scenario.hasPrefix("post-start-"), !sessionID.isEmpty {
            if scenario == "post-start-backend-exit" {
                let pidFile = directory.appendingPathComponent(".cmux-controlled-backend-pid")
                guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)),
                      let backend = AgentPIDProcessIdentity.processSnapshot(pid: pid),
                      let supervisor = AgentPIDProcessIdentity.processSnapshot(pid: backend.parentPID),
                      supervisor.parentPID == getpid(),
                      AgentPIDProcessIdentity(pid: pid) == backend.identity,
                      kill(pid, SIGTERM) == 0 else { throw POSIXError(.ESRCH) }
            } else {
                try await store.writeLine(sessionId: sessionID, text: acceptedOwnerPrompt)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !events.contains(where: { $0["type"] as? String == "provider.exit" }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let activeBeforeStop = store.hasActiveProviderSession
            let exitBeforeStop = events.last { $0["type"] as? String == "provider.exit" }
            let failureReported = events.contains {
                $0["stream"] as? String == "stderr" && !($0["text"] as? String ?? "").isEmpty
            }
            let configurationChangedReported = events.contains {
                ($0["text"] as? String)?.hasSuffix(": configurationChanged\n") == true
            }
            store.closeAll()
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            while store.hasActiveProviderSession, ContinuousClock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return [
                "startError": startError, "activeBeforeStop": activeBeforeStop,
                "exitStatusBeforeStop": exitBeforeStop?["status"] as? Int ?? -1,
                "exitStopRequestedBeforeStop": exitBeforeStop?["stopRequested"] as? Bool ?? false,
                "failureReportedBeforeStop": failureReported, "stopped": !store.hasActiveProviderSession,
                "configurationChangedReported": configurationChangedReported,
            ]
        }
        var ownerInputError = ""
        if scenario == "owner-input", !sessionID.isEmpty {
            do {
                try await store.writeLine(sessionId: sessionID, text: acceptedOwnerPrompt)
            } catch { ownerInputError = String(describing: error) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                let traceFile = directory.appendingPathComponent(".cmux-controlled-copilot-trace")
                if let trace = try? String(contentsOf: traceFile, encoding: .utf8),
                   trace.contains("response-written:session.tools.listPendingRequests at ") { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        var manualInputObserved = false
        if !manualSessionID.isEmpty {
            try await store.writeLine(sessionId: manualSessionID, text: "controlled manual input")
            let inputFile = directory.appendingPathComponent(".cmux-controlled-manual-input")
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: inputFile.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            manualInputObserved = try String(contentsOf: inputFile, encoding: .utf8)
                .contains("controlled manual input")
        }
        var queued: Task<Bool, Never>?
        if scenario == "stop-queued-input", !sessionID.isEmpty {
            let target = sessionID
            queued = Task { @MainActor in
                do {
                    try await store.writeLine(sessionId: target, text: "must not reach controlled peer")
                    return false
                } catch { return true }
            }
        }
        if scenario != "manual-first" {
            do {
                _ = try await store.start(
                    plan: .init(provider: .claude, executableURL: executable, arguments: [], environment: [:]),
                    workingDirectory: directory.path
                )
            } catch {
                manualStartError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
            }
        }
        if scenario == "cleanup-unknown", !sessionID.isEmpty {
            let pidFile = directory.appendingPathComponent(".cmux-controlled-backend-pid")
            guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)),
                  let backend = AgentPIDProcessIdentity.processSnapshot(pid: pid),
                  let supervisor = AgentPIDProcessIdentity.processSnapshot(pid: backend.parentPID),
                  supervisor.parentPID == getpid() else { throw POSIXError(.ESRCH) }
            defer {
                if AgentPIDProcessIdentity(pid: pid) == backend.identity { _ = kill(pid, SIGKILL) }
            }
            guard kill(supervisor.identity.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            try await ManagedSessionLifetimeFixture.wait {
                AgentPIDProcessIdentity(pid: supervisor.identity.pid) != supervisor.identity
            }
            try store.stop(sessionId: sessionID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !events.contains(where: { ($0["text"] as? String)?.contains("cleanup is unverified") == true }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let stillOwned = store.hasActiveProviderSession
            manualStartError = ""
            do {
                _ = try await store.start(
                    plan: .init(provider: .claude, executableURL: executable, arguments: [], environment: [:]),
                    workingDirectory: directory.path
                )
            } catch {
                manualStartError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
            }
            if AgentPIDProcessIdentity(pid: pid) == backend.identity {
                guard kill(pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            }
            try await ManagedSessionLifetimeFixture.wait { AgentPIDProcessIdentity(pid: pid) != backend.identity }
            return [
                "startError": startError, "manualStartError": manualStartError,
                "activeAfterFailedClose": stillOwned,
                "cleanupErrorReported": events.contains {
                    ($0["text"] as? String)?.contains("supervisorCleanupUnverified") == true
                },
                "fixtureBackendAbsent": true,
            ]
        }
        if !sessionID.isEmpty { try store.stop(sessionId: sessionID) }
        store.closeAll()
        let queuedInputRejected = await queued?.value ?? false
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while store.hasActiveProviderSession, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let traceFile = directory.appendingPathComponent(".cmux-controlled-copilot-trace")
        let trace = FileManager.default.fileExists(atPath: traceFile.path)
            ? try String(contentsOf: traceFile, encoding: .utf8) : ""
        let exitEvent = events.last { $0["type"] as? String == "provider.exit" }
        return [
            "startError": startError, "activeAfterStart": active,
            "manualStartError": manualStartError, "stopped": !store.hasActiveProviderSession,
            "duplicateError": duplicateError, "queuedInputRejected": queuedInputRejected,
            "peerStarted": trace.contains("peer-started"),
            "wireSendObserved": trace.split(separator: "\n").contains("session.send"),
            "workReadbacksObserved": [
                "session.tasks.refresh", "session.tasks.list", "session.schedule.list",
                "session.tools.listPendingRequests",
            ].allSatisfy { trace.contains("response-written:\($0) at ") },
            "observedReservation": observedReservation,
            "ownerInputError": ownerInputError, "manualInputObserved": manualInputObserved,
            "permissionRefused": permissionRefused, "subsequentInputRefused": subsequentInputRefused,
            "exitStatus": exitEvent?["status"] as? Int ?? -1,
            "exitStopRequested": exitEvent?["stopRequested"] as? Bool ?? false,
            "startupErrorReported": events.contains {
                ($0["text"] as? String)?.contains("configurationMismatch") == true
            },
        ]
    }
}
