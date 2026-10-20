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
        let peerScenario = scenario == "raw-coding-mandate-refused" ? "owner-tool-before-send-ack"
            : scenario == "startup-held" ? "inherited-mcp"
            : scenario == "post-start-protocol-hold" ? "owner-configuration-changed" : "owner-early-root"
        try JSONSerialization.data(withJSONObject: ["scenario": peerScenario, "callbackFile": ""])
            .write(to: directory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        if scenario.hasPrefix("host-") {
            return try await runHostRetention(scenario, executable: executable, directory: directory)
        }
        let store = AgentSessionProcessStore()
        var events: [[String: Any]] = []
        store.eventSink = { events.append($0) }
        if scenario.hasPrefix("native-coding-") {
            return try await runNativeCoding(scenario, store: store, executable: executable, directory: directory)
        }
        if scenario == "copilot-browser-refused" {
            var errors: [String] = []
            for method in ["provider.select", "provider.start"] {
                let request = try AgentSessionBridgeRequest(body: [
                    "id": UUID().uuidString, "method": method, "params": ["providerId": "copilot"],
                ])
                do {
                    _ = try request.providerID()
                    errors.append("")
                } catch {
                    errors.append((error as? AgentSessionBridgeError)?.code ?? String(describing: error))
                }
            }
            let manualProviders = try ["codex", "claude", "opencode"].map { value in
                try AgentSessionBridgeRequest(body: [
                    "id": UUID().uuidString, "method": "provider.start", "params": ["providerId": value],
                ]).providerID().rawValue
            }
            return ["supported": AgentSessionProviderID(rawValue: "copilot") != nil,
                    "errors": errors, "manualProviders": manualProviders]
        }
        if scenario == "copilot-provider-contract" {
            guard let provider = AgentSessionProviderID(rawValue: "copilot") else {
                return ["supported": false]
            }
            return [
                "supported": true,
                "executableName": provider.executableName,
                "transportKind": provider.transportKind,
                "arguments": provider.launchArguments,
                "autoStart": provider.shouldAutoStartSession,
            ]
        }
        if scenario == "copilot-manual-refused" {
            guard let provider = AgentSessionProviderID(rawValue: "copilot") else {
                return ["startError": "invalidProvider", "active": false, "started": false]
            }
            var startError = ""
            do {
                _ = try await store.start(
                    plan: .init(
                        provider: provider, executableURL: executable,
                        arguments: ["--fixture-store-manual"], environment: [:]
                    ),
                    workingDirectory: directory.path, launcher: .init(supervisorExecutableURL: executable)
                )
            } catch {
                startError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
            }
            let active = store.hasActiveProviderSession
            let started = events.contains { $0["type"] as? String == "provider.started" }
            store.closeAll()
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while store.hasActiveProviderSession, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return ["startError": startError, "active": active, "started": started,
                    "stopped": !store.hasActiveProviderSession]
        }
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
                executableURL: executable, workingDirectory: directory.path,
                codingProjectMandate: scenario == "raw-coding-mandate-refused" ? UUID() : nil,
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
            "peerStarted": FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".cmux-controlled-backend-pid").path
            ),
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

    @MainActor static func runHostRetention(
        _ scenario: String, executable: URL, directory: URL
    ) async throws -> [String: Any] {
        if scenario == "host-healthy-concurrency" || scenario.hasPrefix("host-fence-") {
            var stores: [AgentSessionProcessStore] = []
            defer { stores.forEach { $0.closeAll() } }
            func start(
                _ name: String, onAuthorization: (() -> Void)? = nil, onReservation: (() -> Void)? = nil
            ) async throws -> AgentSessionProcessStore {
                let project = directory.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
                let file = project.appendingPathComponent("controlled-project.txt")
                try Data("before\n".utf8).write(to: file)
                try JSONSerialization.data(withJSONObject: [
                    "scenario": "owner-tool-native-coding", "callbackFile": file.path,
                ]).write(to: project.appendingPathComponent(".cmux-controlled-copilot-scenario"))
                let store = AgentSessionProcessStore()
                stores.append(store)
                store.activeProviderSink = { if $0 { onReservation?() } }
                var constructed = false
                guard let owner = AgentSessionManagedCopilotLaunch.NativeCodingOwner(
                    newPanelID: UUID(), workspaceID: UUID(), rendererID: "react",
                    workingDirectory: project.path, owningStore: store, isCurrentOwner: {
                        if constructed { onAuthorization?() }
                        return true
                    }
                ) else { throw POSIXError(.EINVAL) }
                constructed = true
                _ = try await store.startManagedCopilot(
                    scope: owner.scope, executableURL: executable, workingDirectory: owner.workingDirectory,
                    codingProjectMandate: owner.projectMandate, nativeCodingOwner: owner,
                    launcher: .init(supervisorExecutableURL: executable)
                )
                return store
            }
            let first = try await start("first")
            if scenario.hasPrefix("host-fence-") {
                let pidFile = directory.appendingPathComponent("first/.cmux-controlled-backend-pid")
                guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)),
                      let backend = AgentPIDProcessIdentity.processSnapshot(pid: pid),
                      let supervisor = AgentPIDProcessIdentity.processSnapshot(pid: backend.parentPID),
                      supervisor.parentPID == getpid() else { throw POSIXError(.ESRCH) }
                defer {
                    if AgentPIDProcessIdentity(pid: pid) == backend.identity { _ = kill(pid, SIGKILL) }
                }
                var killFailure: Int32 = 0
                var startError = ""
                do {
                    _ = try await start(
                        "candidate",
                        onAuthorization: scenario == "host-fence-after-owner-callback" ? { first.closeAll() } : nil,
                        onReservation: scenario == "host-fence-before-backend-launch" ? {
                            if kill(supervisor.identity.pid, SIGKILL) != 0 { killFailure = errno }
                            first.closeAll()
                        } : nil
                    )
                } catch { startError = String(describing: error) }
                guard killFailure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: killFailure) ?? .EIO) }
                let peerStarted = FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("candidate/.cmux-controlled-backend-pid").path
                )
                stores.forEach { $0.closeAll() }
                if scenario == "host-fence-before-backend-launch",
                   AgentPIDProcessIdentity(pid: pid) == backend.identity {
                    guard kill(pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while ContinuousClock.now < deadline {
                    let othersClosed = stores.filter { $0 !== first }.allSatisfy { !$0.hasActiveProviderSession }
                    let originalClosed = scenario == "host-fence-before-backend-launch" ||
                        !first.hasActiveProviderSession
                    if othersClosed && originalClosed &&
                        AgentPIDProcessIdentity(pid: pid) != backend.identity &&
                        AgentPIDProcessIdentity(pid: supervisor.identity.pid) != supervisor.identity { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let controlledChildrenAbsent = AgentPIDProcessIdentity(pid: pid) != backend.identity &&
                    AgentPIDProcessIdentity(pid: supervisor.identity.pid) != supervisor.identity &&
                    stores.filter { $0 !== first }.allSatisfy { !$0.hasActiveProviderSession }
                guard controlledChildrenAbsent else { throw POSIXError(.EBUSY) }
                return [
                    "startError": startError, "peerStarted": peerStarted,
                    "controlledChildrenAbsent": controlledChildrenAbsent,
                ]
            }
            let second = try await start("second")
            let twoHealthyStoresActive = first.hasActiveProviderSession && second.hasActiveProviderSession
            first.closeAll()
            var pendingCleanupStartError = ""
            do { _ = try await start("pending-cleanup") }
            catch { pendingCleanupStartError = String(describing: error) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while first.hasActiveProviderSession, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard !first.hasActiveProviderSession else { throw POSIXError(.EBUSY) }
            let third = try await start("after-verified-cleanup")
            let freshStartAfterVerifiedCleanup = second.hasActiveProviderSession && third.hasActiveProviderSession
            stores.forEach { $0.closeAll() }
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            while stores.contains(where: \.hasActiveProviderSession), ContinuousClock.now < closeDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard !stores.contains(where: \.hasActiveProviderSession) else { throw POSIXError(.EBUSY) }
            return [
                "twoHealthyStoresActive": twoHealthyStoresActive,
                "pendingCleanupStartError": pendingCleanupStartError,
                "pendingCleanupPeerStarted": FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("pending-cleanup/.cmux-controlled-backend-pid").path
                ),
                "freshStartAfterVerifiedCleanup": freshStartAfterVerifiedCleanup,
                "allStopped": true,
            ]
        }
        var originalStore: AgentSessionProcessStore? = AgentSessionProcessStore()
        weak var originalReference = originalStore
        let original = try await runNativeCoding(
            scenario == "host-command-held" ? "native-coding-command-held" :
                scenario == "host-held-retention" ? "native-coding-cleanup-unknown" : "native-coding-owner-check",
            store: originalStore!, executable: executable, directory: directory
        )
        originalStore = nil
        for _ in 0..<20 { await Task.yield() }
        if scenario == "host-verified-release" {
            return [
                "originalStartError": original["startError"] ?? "missing",
                "originalStopped": original["stopped"] ?? false,
                "storeRetainedAfterVerifiedCleanup": originalReference != nil,
            ]
        }
        let freshDirectory = directory.appendingPathComponent("fresh-owner", isDirectory: true)
        try FileManager.default.createDirectory(
            at: freshDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let freshProject = freshDirectory.appendingPathComponent("controlled-project.txt")
        try Data("before\n".utf8).write(to: freshProject)
        try JSONSerialization.data(withJSONObject: [
            "scenario": "owner-tool-native-coding", "callbackFile": freshProject.path,
        ]).write(to: freshDirectory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        let freshStore = AgentSessionProcessStore()
        guard let owner = AgentSessionManagedCopilotLaunch.NativeCodingOwner(
            newPanelID: UUID(), workspaceID: UUID(), rendererID: "solid",
            workingDirectory: freshDirectory.path, owningStore: freshStore, isCurrentOwner: { true }
        ) else { throw POSIXError(.EINVAL) }
        var freshStartError = ""
        do {
            _ = try await freshStore.startManagedCopilot(
                scope: owner.scope, executableURL: executable, workingDirectory: owner.workingDirectory,
                codingProjectMandate: owner.projectMandate, nativeCodingOwner: owner,
                launcher: .init(supervisorExecutableURL: executable)
            )
        } catch {
            freshStartError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
        }
        let peerFile = freshDirectory.appendingPathComponent(".cmux-controlled-backend-pid")
        let freshPeerStarted = FileManager.default.fileExists(atPath: peerFile.path)
        freshStore.closeAll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while freshStore.hasActiveProviderSession, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !freshStore.hasActiveProviderSession else { throw POSIXError(.EBUSY) }
        let traceFile = freshDirectory.appendingPathComponent(".cmux-controlled-copilot-trace")
        let trace = FileManager.default.fileExists(atPath: traceFile.path)
            ? try String(contentsOf: traceFile, encoding: .utf8) : ""
        return [
            "originalStartError": original["startError"] ?? "missing",
            "originalCleanupUnverified": original["failureReported"] ?? false,
            "commandHeldUncertain": original["commandHeldUncertain"] ?? false,
            "heldStoreRetained": originalReference != nil,
            "freshStartError": freshStartError, "freshPeerStarted": freshPeerStarted,
            "freshWireSendObserved": trace.split(separator: "\n").contains("session.send"),
            "fixtureBackendsAbsent": original["fixtureBackendAbsent"] as? Bool == true &&
                !freshStore.hasActiveProviderSession,
        ]
    }

    @MainActor static func runNativeCoding(
        _ scenario: String, store: AgentSessionProcessStore, executable: URL, directory: URL
    ) async throws -> [String: Any] {
        var nativeEvents: [[String: Any]] = []
        store.eventSink = { nativeEvents.append($0) }
        let projectFile = directory.appendingPathComponent("controlled-project.txt")
        try Data("before\n".utf8).write(to: projectFile)
        try JSONSerialization.data(withJSONObject: [
            "scenario": scenario == "native-coding-command-held" ? "owner-tool-uncertain-command" :
                "owner-tool-native-coding", "callbackFile": projectFile.path,
        ]).write(to: directory.appendingPathComponent(".cmux-controlled-copilot-scenario"))
        var currentOwner = true
        var closeDuringOwnerCheck = false
        guard let nativeOwner = AgentSessionManagedCopilotLaunch.NativeCodingOwner(
            newPanelID: UUID(), workspaceID: UUID(), rendererID: "react",
            workingDirectory: directory.path, owningStore: store, isCurrentOwner: { [weak store] in
                if closeDuringOwnerCheck {
                    closeDuringOwnerCheck = false
                    store?.closeAll()
                }
                return currentOwner
            }
        ) else { return ["nativeOwnerAvailable": false] }
        let ownerAcceptedBeforeStart = store.ownsManagedCodingOwner(nativeOwner)
        var scope = nativeOwner.scope
        var mandate = nativeOwner.projectMandate
        var workingDirectory = nativeOwner.workingDirectory
        let targetStore = scenario == "native-coding-other-store" ? AgentSessionProcessStore() : store
        var reservedSnapshot: [String: Any] = [:]
        store.activeProviderSink = { [weak store] active in
            guard active, let store else { return }
            reservedSnapshot = store.nativeManagedSessionSnapshot ?? [:]
            if scenario == "native-coding-owner-lost-before-launch" {
                Task { @MainActor in currentOwner = false }
            }
        }
        if scenario == "native-coding-revoked" { nativeOwner.revoke() }
        if scenario == "native-coding-wrong-workspace" {
            scope = .init(hostInstance: scope.hostInstance, workspaceID: UUID(),
                          surfaceID: scope.surfaceID, generation: scope.generation)
        }
        if scenario == "native-coding-wrong-surface" {
            scope = .init(hostInstance: scope.hostInstance, workspaceID: scope.workspaceID,
                          surfaceID: UUID(), generation: scope.generation)
        }
        if scenario == "native-coding-wrong-generation" {
            scope = .init(hostInstance: scope.hostInstance, workspaceID: scope.workspaceID,
                          surfaceID: scope.surfaceID, generation: scope.generation + 1)
        }
        if scenario == "native-coding-wrong-host" {
            scope = .init(hostInstance: UUID(), workspaceID: scope.workspaceID,
                          surfaceID: scope.surfaceID, generation: scope.generation)
        }
        if scenario == "native-coding-wrong-mandate" { mandate = UUID() }
        if scenario == "native-coding-wrong-directory" {
            let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: false)
            workingDirectory = otherDirectory.path
        }
        var startError = ""
        var sessionID = ""
        do {
            sessionID = try await targetStore.startManagedCopilot(
                scope: scope, executableURL: executable, workingDirectory: workingDirectory,
                codingProjectMandate: mandate, nativeCodingOwner: nativeOwner,
                launcher: .init(supervisorExecutableURL: executable)
            ).sessionId
        } catch {
            startError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
        }
        let active = targetStore.hasActiveProviderSession
        let runningSnapshot = targetStore.nativeManagedSessionSnapshot ?? [:]
        closeDuringOwnerCheck = scenario == "native-coding-owner-check-reentrant"
        let ownerAcceptedWhileRunning = targetStore.ownsManagedCodingOwner(nativeOwner)
        let foreignStoreAcceptedOwner = AgentSessionProcessStore().ownsManagedCodingOwner(nativeOwner)
        if scenario == "native-coding-cleanup-unknown", !sessionID.isEmpty {
            let pidFile = directory.appendingPathComponent(".cmux-controlled-backend-pid")
            guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)),
                  let backend = AgentPIDProcessIdentity.processSnapshot(pid: pid),
                  let supervisor = AgentPIDProcessIdentity.processSnapshot(pid: backend.parentPID),
                  supervisor.parentPID == getpid() else { throw POSIXError(.ESRCH) }
            defer {
                if AgentPIDProcessIdentity(pid: pid) == backend.identity { _ = kill(pid, SIGKILL) }
            }
            guard kill(supervisor.identity.pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !nativeEvents.contains(where: {
                ($0["text"] as? String)?.contains("cleanup is unverified") == true
            }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let occupied = targetStore.hasActiveProviderSession
            let snapshotAfterFailure = targetStore.nativeManagedSessionSnapshot ?? [:]
            let lifecycleEvents = nativeEvents.filter { $0["type"] as? String == "provider.nativeSession" }
            let exitReported = nativeEvents.contains { $0["type"] as? String == "provider.exit" }
            let failureReported = nativeEvents.contains {
                ($0["text"] as? String)?.contains("cleanup is unverified") == true
            }
            if AgentPIDProcessIdentity(pid: pid) == backend.identity {
                guard kill(pid, SIGKILL) == 0 else { throw POSIXError(.ESRCH) }
            }
            try await ManagedSessionLifetimeFixture.wait { AgentPIDProcessIdentity(pid: pid) != backend.identity }
            return [
                "startError": startError, "runningSnapshot": runningSnapshot,
                "snapshotAfterFailure": snapshotAfterFailure, "nativeLifecycleEvents": lifecycleEvents,
                "occupiedAfterFailure": occupied, "exitReported": exitReported,
                "failureReported": failureReported, "fixtureBackendAbsent": true,
            ]
        }
        var inputError = ""
        var queuedInput: Task<Bool, Never>?
        if !sessionID.isEmpty {
            if scenario == "native-coding-owner-lost" { currentOwner = false }
            if scenario == "native-coding-close-queued-input" {
                let target = sessionID
                queuedInput = Task { @MainActor in
                    do {
                        try await targetStore.writeLine(sessionId: target, text: acceptedOwnerPrompt)
                        return false
                    } catch { return true }
                }
                nativeOwner.revoke()
            } else if ["native-coding-input", "native-coding-owner-lost", "native-coding-command-held"].contains(scenario) {
                do {
                    try await targetStore.writeLine(sessionId: sessionID, text: acceptedOwnerPrompt)
                } catch {
                    inputError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
                }
                if scenario == "native-coding-input" {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                    while ContinuousClock.now < deadline {
                        let traceFile = directory.appendingPathComponent(".cmux-controlled-copilot-trace")
                        if let trace = try? String(contentsOf: traceFile, encoding: .utf8),
                           trace.contains("response-written:session.tools.listPendingRequests at ") { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
            }
            if scenario == "native-coding-command-held" {
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while !nativeEvents.contains(where: {
                    $0["type"] as? String == "provider.exit" ||
                        ($0["text"] as? String)?.contains("cleanup is unverified") == true
                }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                targetStore.closeAll()
                let pidFile = directory.appendingPathComponent(".cmux-controlled-backend-pid")
                guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)) else {
                    throw POSIXError(.ESRCH)
                }
                guard AgentPIDProcessIdentity(pid: pid) == nil else { throw POSIXError(.EBUSY) }
                return [
                    "startError": startError, "fixtureBackendAbsent": true,
                    "failureReported": nativeEvents.contains {
                        ($0["text"] as? String)?.contains("cleanup is unverified") == true
                    },
                    "commandHeldUncertain": nativeEvents.contains {
                        ($0["text"] as? String)?.contains("commandHeld:uncertainTermination") == true
                    },
                ]
            }
        }
        targetStore.closeAll()
        let ownerAcceptedWhileClosing = targetStore.ownsManagedCodingOwner(nativeOwner)
        let queuedInputRejected = await queuedInput?.value ?? false
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while targetStore.hasActiveProviderSession, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        var replayError = ""
        if scenario == "native-coding-replay" {
            do {
                _ = try await targetStore.startManagedCopilot(
                    scope: nativeOwner.scope, executableURL: executable, workingDirectory: nativeOwner.workingDirectory,
                    codingProjectMandate: nativeOwner.projectMandate, nativeCodingOwner: nativeOwner,
                    launcher: .init(supervisorExecutableURL: executable)
                )
            } catch {
                replayError = (error as? AgentSessionBridgeError)?.code ?? String(describing: error)
            }
            targetStore.closeAll()
            let replayDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            while targetStore.hasActiveProviderSession, ContinuousClock.now < replayDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let traceFile = directory.appendingPathComponent(".cmux-controlled-copilot-trace")
        let trace = FileManager.default.fileExists(atPath: traceFile.path)
            ? try String(contentsOf: traceFile, encoding: .utf8) : ""
        let executionFile = URL(fileURLWithPath: projectFile.path + ".executions")
        return [
            "nativeOwnerAvailable": true, "startError": startError, "activeAfterStart": active,
            "ownerAcceptedBeforeStart": ownerAcceptedBeforeStart,
            "ownerAcceptedWhileRunning": ownerAcceptedWhileRunning,
            "foreignStoreAcceptedOwner": foreignStoreAcceptedOwner,
            "ownerAcceptedWhileClosing": ownerAcceptedWhileClosing,
            "ownerAcceptedAfterClose": targetStore.ownsManagedCodingOwner(nativeOwner),
            "nativeFailureEvents": nativeEvents.filter {
                $0["type"] as? String == "provider.output" && $0["stream"] as? String == "stderr"
            },
            "sessionID": sessionID, "reservedSnapshot": reservedSnapshot, "runningSnapshot": runningSnapshot,
            "snapshotCleared": targetStore.nativeManagedSessionSnapshot == nil,
            "inputError": inputError, "queuedInputRejected": queuedInputRejected,
            "replayError": replayError, "stopped": !targetStore.hasActiveProviderSession,
            "peerStarted": FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".cmux-controlled-backend-pid").path
            ),
            "wireSendObserved": trace.split(separator: "\n").contains("session.send"),
            "workReadbacksObserved": [
                "session.tasks.refresh", "session.tasks.list", "session.schedule.list",
                "session.tools.listPendingRequests",
            ].allSatisfy { trace.contains("response-written:\($0) at ") },
            "projectContents": try String(contentsOf: projectFile, encoding: .utf8),
            "commandExecutions": FileManager.default.fileExists(atPath: executionFile.path)
                ? try String(contentsOf: executionFile, encoding: .utf8) : "",
        ]
    }
}
