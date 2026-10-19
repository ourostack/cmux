import Foundation

/// Gives managed provider processes an owner that can outlive an app crash.
struct AgentSessionOwnedProcessLauncher {
    private let supervisorExecutableURL: URL?

    init(supervisorExecutableURL: URL? = Bundle.main.url(forResource: "cmux", withExtension: nil, subdirectory: "bin")) {
        self.supervisorExecutableURL = supervisorExecutableURL
    }

    func prepareManaged(
        nonce: UUID, executableURL: URL, arguments: [String],
        workingDirectory: String, environment: [String: String]
    ) throws -> Process {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.utf8.contains(0),
              workingDirectory.hasPrefix("/"), !workingDirectory.utf8.contains(0),
              !arguments.contains(where: { $0.utf8.contains(0) }),
              !environment.contains(where: { key, value in
                  key.isEmpty || key.contains("=") || key.utf8.contains(0) || value.utf8.contains(0)
              }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try prepareProcess(
            arguments: ["__managed-agent-process-supervisor", nonce.uuidString, executableURL.path] + arguments,
            directory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL,
            environment: environment, unavailableProvider: "managed"
        )
    }

    func prepare(
        plan: AgentSessionLaunchPlan,
        workingDirectory: String?,
        environment: [String: String]
    ) throws -> Process {
        let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try prepareProcess(
            arguments: ["__owned-process-supervisor", plan.executableURL.path] + plan.arguments,
            directory: directory.flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            },
            environment: environment, unavailableProvider: plan.provider.displayName
        )
    }

    private func prepareProcess(
        arguments: [String], directory: URL?, environment: [String: String],
        unavailableProvider: String
    ) throws -> Process {
        guard let supervisorExecutableURL else {
            throw AgentSessionBridgeError.providerNotReady(unavailableProvider)
        }
        let process = Process()
        process.executableURL = supervisorExecutableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        return process
    }
}
