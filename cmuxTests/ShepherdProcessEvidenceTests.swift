import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct ShepherdProcessEvidenceTests {
    @Test(arguments: [
        ("/opt/bin/claude", "claude"),
        ("/opt/bin/claude-code", "claude"),
        ("/opt/bin/codex", "codex"),
        ("/opt/bin/copilot", "copilot"),
        ("/opt/bin/github-copilot", "copilot"),
    ])
    func bindsDirectAgentToNativeLifetimeAndTerminal(executable: String, agent: String) throws {
        let fixture = ProcessFixture()
        fixture.executable = executable
        let evidence = try #require(fixture.reader.read(surface: { fixture.target }))
        #expect(evidence.processInstance == "42:123456")
        #expect(evidence.agent == agent)
        #expect(evidence.workingDirectory == fixture.directory)
        #expect(evidence.tty == "/dev/ttys123")
    }

    @Test(arguments: ["/bin/sh", "/bin/node", "/bin/bun", "/bin/my-copilot",
                      "/tmp/copilot-helper", "/opt/claude/versions/2.0", "claude", ""])
    func argvOrInheritedAgentHintsCannotIdentifyAnotherExecutable(executable: String) {
        let fixture = ProcessFixture()
        fixture.executable = executable
        #expect(fixture.reader.read(surface: { fixture.target }) == nil)
    }

    @Test(arguments: ["start", "birth", "tty", "cwd", "executable", "surface"])
    func missingNativeFactCannotBecomeProcessProof(field: String) {
        let fixture = ProcessFixture()
        fixture.missing = field
        #expect(fixture.reader.read(surface: { fixture.missing == "surface" ? nil : fixture.target }) == nil)
    }

    @Test(arguments: ["start", "birth", "tty", "cwd", "executable"])
    func changingKernelFactsCannotBeCombinedAcrossAnObservation(field: String) {
        let fixture = ProcessFixture()
        fixture.changing = field
        #expect(fixture.reader.read(surface: { fixture.target }) == nil)
    }

    @Test(arguments: ["pid", "generation", "tty", "device", "disappeared"])
    func changedTerminalCannotDonateProcessFactsToItsReplacement(field: String) {
        let fixture = ProcessFixture()
        var reads = 0
        let evidence = fixture.reader.read {
            reads += 1
            guard reads > 1 else { return fixture.target }
            var target = fixture.target
            switch field {
            case "pid": target.pid = 43
            case "generation": target.generation = 2
            case "tty": target.tty = "/dev/ttys124"
            case "device": target.ttyDevice = 124
            default: return nil
            }
            return target
        }
        #expect(evidence == nil)
    }

    @Test(arguments: [0, -1, 124])
    func processTTYMustMatchTheExactLiveSurfaceDevice(device: Int64) {
        let fixture = ProcessFixture()
        fixture.device = device
        #expect(fixture.reader.read(surface: { fixture.target }) == nil)
    }

    @Test(arguments: ["relative", "/path/that/does/not/exist", "/dev/null", ""])
    func directoryMustBeAnExistingAbsoluteDirectory(directory: String) {
        let fixture = ProcessFixture()
        fixture.directory = directory
        #expect(fixture.reader.read(surface: { fixture.target }) == nil)
    }

    @Test func directoryWhitespaceIsNotSilentlyReboundToAnotherProject() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual = parent.appendingPathComponent("project ")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let fixture = ProcessFixture()
        fixture.directory = actual.path
        let evidence = try #require(fixture.reader.read(surface: { fixture.target }))
        #expect(evidence.workingDirectory.hasSuffix("/project ") == true)
    }

    @Test func invalidTargetOrKernelLifetimeIsUnknown() {
        for mutation in ["pid", "generation", "tty", "device", "start", "birthPID"] {
            let fixture = ProcessFixture()
            switch mutation {
            case "pid": fixture.target.pid = 0
            case "generation": fixture.target.generation = 0
            case "tty": fixture.target.tty = ""
            case "device": fixture.target.ttyDevice = 0
            default: fixture.invalid = mutation
            }
            #expect(fixture.reader.read(surface: { fixture.target }) == nil)
        }
    }

    @Test func resolvesDirectorySymlinksWithoutChangingTheProcessScope() throws {
        let fixture = ProcessFixture()
        fixture.directory = "/var"
        let evidence = try #require(fixture.reader.read(surface: { fixture.target }))
        #expect(evidence.workingDirectory == "/private/var")
    }

    @Test func liveKernelReaderDoesNotTreatThisTestRunnerAsAnAgent() {
        let reader = ShepherdProcessEvidenceReader(processStart: { _ in 123456 })
        #expect(reader.read {
            .init(pid: getpid(), generation: 1, tty: "/dev/ttys123", ttyDevice: 123)
        } == nil)
    }

    @Test func kernelPathAndRawDirectoryComeFromTheLiveProcess() throws {
        let parent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let directory = parent.appendingPathComponent("project ")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        child.currentDirectoryURL = directory
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let path = try #require(ShepherdProcessEvidenceReader.kernelExecutablePath(pid: child.processIdentifier))
        #expect(path == "/bin/sleep")
        #expect(TerminalWorkingDirectoryResolver.rawProcessCurrentWorkingDirectory(
            pid: child.processIdentifier
        ) == directory.path)
        #expect(ShepherdProcessEvidenceReader.kernelExecutablePath(pid: 0) == nil)
        #expect(TerminalWorkingDirectoryResolver.rawProcessCurrentWorkingDirectory(pid: 0) == nil)
    }
}

final class ProcessFixture {
    var target = ShepherdProcessSurface(pid: 42, generation: 1, tty: "/dev/ttys123", ttyDevice: 123)
    var executable: String? = "/opt/bin/claude"
    var directory = "/private/tmp"
    var device: Int64? = 123
    var missing: String?
    var changing: String?
    var invalid: String?
    private var reads: [String: Int] = [:]

    private func changed(_ field: String) -> Bool {
        reads[field, default: 0] += 1
        return changing == field && reads[field, default: 0] > 1
    }

    var reader: ShepherdProcessEvidenceReader {
        ShepherdProcessEvidenceReader(
            processStart: { pid in
                #expect(pid == 42)
                return self.missing == "start" ? nil : (self.invalid == "start" ? 0 : (self.changed("start") ? 654321 : 123456))
            },
            processIdentity: { pid in
                #expect(pid == 42)
                return self.missing == "birth" ? nil : .init(
                    pid: self.invalid == "birthPID" ? 43 : pid,
                    startSeconds: 100, startMicroseconds: self.changed("birth") ? 2 : 1
                )
            },
            processTTY: { pid in
                #expect(pid == 42)
                return self.missing == "tty" ? nil : (self.changed("tty") ? 124 : self.device)
            },
            workingDirectory: { pid in
                #expect(pid == 42)
                return self.missing == "cwd" ? nil : (self.changed("cwd") ? "/private/var" : self.directory)
            },
            executablePath: { pid in
                #expect(pid == 42)
                return self.missing == "executable" ? nil : (self.changed("executable") ? "/opt/bin/codex" : self.executable)
            }
        )
    }
}
