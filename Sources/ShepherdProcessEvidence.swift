import CmuxFoundation
import CmuxControlSocket
import Darwin
import Foundation

struct ShepherdProcessSurface: Equatable {
    var pid: pid_t
    var generation: UInt64
    var tty: String
    var ttyDevice: Int64
}

struct ShepherdProcessEvidence: Equatable {
    let surface: ShepherdProcessSurface
    let processInstance: String
    let agent: String
    let workingDirectory: String
    let tty: String
    let birth: AgentPIDProcessIdentity
    let executablePath: String
}

struct ShepherdProcessEvidenceReader {
    var processStart: (pid_t) -> UInt64?
    var processIdentity: (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) }
    var processTTY: (pid_t) -> Int64? = { agentLiveProcessIdentity(pid: $0)?.ttyDevice }
    var workingDirectory: (pid_t) -> String? = {
        TerminalWorkingDirectoryResolver.rawProcessCurrentWorkingDirectory(pid: $0)
    }
    var executablePath: (pid_t) -> String? = Self.kernelExecutablePath
    var registeredClaudeRoot: ((pid_t, String, AgentPIDProcessIdentity) -> Bool)?

    func read(surface: () -> ShepherdProcessSurface?) -> ShepherdProcessEvidence? {
        guard let target = surface(), target.pid > 0, target.generation > 0,
              target.tty.hasPrefix("/dev/"), target.ttyDevice > 0,
              let start = processStart(target.pid), start > 0,
              let birth = processIdentity(target.pid), birth.pid == target.pid,
              let device = processTTY(target.pid), device == target.ttyDevice,
              let executable = executablePath(target.pid),
              let agent = identifiedAgent(pid: target.pid, executable: executable, birth: birth),
              let rawDirectory = workingDirectory(target.pid),
              let directory = Self.canonicalDirectory(rawDirectory) else { return nil }

        // The absolute lifetime encloses every other kernel fact, including the
        // zombie-aware sysctl identity. Never mix independently validated epochs.
        guard let finalDirectory = workingDirectory(target.pid), finalDirectory == rawDirectory,
              Self.canonicalDirectory(finalDirectory) == directory,
              executablePath(target.pid) == executable,
              processTTY(target.pid) == device,
              identifiedAgent(pid: target.pid, executable: executable, birth: birth) == agent,
              processIdentity(target.pid) == birth,
              processStart(target.pid) == start,
              surface() == target else { return nil }
        return ShepherdProcessEvidence(
            surface: target, processInstance: "\(target.pid):\(start)", agent: agent,
            workingDirectory: directory, tty: target.tty, birth: birth, executablePath: executable
        )
    }

    static func kernelExecutablePath(pid: pid_t) -> String? {
        ShepherdHookExecutableIdentity.kernelExecutablePath(pid: pid)
    }

    private func identifiedAgent(
        pid: pid_t, executable: String, birth: AgentPIDProcessIdentity
    ) -> String? {
        Self.directAgent(executable: executable)
            ?? (registeredClaudeRoot?(pid, executable, birth) == true ? "claude" : nil)
    }

    private static func directAgent(executable: String) -> String? {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0) else { return nil }
        switch (executable as NSString).lastPathComponent {
        case "claude", "claude-code": return "claude"
        case "codex": return "codex"
        case "copilot", "github-copilot": return "copilot"
        default: return nil
        }
    }

    private static func canonicalDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return String(validatingCString: resolved)
    }
}
