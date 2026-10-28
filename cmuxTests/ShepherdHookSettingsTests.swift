#if SHEPHERD_SOURCE_TEST
import CMUXAgentLaunch
import Foundation
import Testing
@testable import cmux

@Suite(.serialized) struct ShepherdHookSettingsTests {
    @Test func replacesOnlyOwnedQueuedHooksAndPreservesUserAndDecisionHooks() throws {
        let fixture = try SettingsFixture()
        let output = try fixture.upgrade()
        let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        #expect(object["effortLevel"] as? String == "high")
        for event in SettingsFixture.events {
            let groups = try #require(hooks[event])
            let guards = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
                ($0["command"] as? String)?.contains("readiness-event") == true
            }
            #expect(guards.count == 1)
            let guardHook = try #require(guards.first)
            #expect(guardHook["async"] == nil)
            #expect(guardHook["timeout"] as? Int == 5)
            #expect(guardHook["onFailure"] as? String
                == (["UserPromptSubmit", "PreToolUse"].contains(event) ? "block" : nil))
        }
        let commands = hooks.values.flatMap { $0 }.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("cmux hooks claude cron-create-guard"))
        #expect(commands.contains("cmux hooks feed --source claude"))
        #expect(commands.contains(fixture.userCommand))
    }

    @Test func sameReceiptIsIdempotentButChangingARegisteredLaunchRefuses() throws {
        let fixture = try SettingsFixture()
        let once = try fixture.upgrade()
        let twice = try ShepherdHookSettings.upgrade(
            settings: once, managedSettings: fixture.base,
            launchID: fixture.launch, cliPath: fixture.cli
        )
        #expect(twice == once)
        #expect(throws: CLIError.self) {
            try ShepherdHookSettings.upgrade(
                settings: once, managedSettings: fixture.base, launchID: UUID(), cliPath: fixture.cli
            )
        }
    }

    @Test(arguments: ["missing", "duplicate", "lookalike", "disabled"])
    func incompleteOrAmbiguousHookCoverageCannotRegisterAProducer(change: String) throws {
        let fixture = try SettingsFixture()
        var object = try #require(JSONSerialization.jsonObject(with: fixture.final) as? [String: Any])
        var hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        let current = try #require(hooks["UserPromptSubmit"])
        switch change {
        case "missing": hooks["UserPromptSubmit"] = []
        case "duplicate": hooks["UserPromptSubmit"] = current + current
        case "lookalike":
            hooks["UserPromptSubmit"] = [[
                "matcher": "", "hooks": [["type": "command", "timeout": 5,
                                         "command": fixture.userCommand]]
            ]]
        default: object["disableAllHooks"] = true
        }
        object["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CLIError.self) {
            try ShepherdHookSettings.upgrade(
                settings: data, managedSettings: fixture.base, launchID: fixture.launch, cliPath: fixture.cli
            )
        }
    }

    @Test func guardedCommandExecutesTheExactQuotedCLIWithNoInheritedFallback() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cmux tool's path")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let fixture = try SettingsFixture(cli: cli.path)
        let object = try #require(JSONSerialization.jsonObject(with: fixture.upgrade()) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        let command = try #require(hooks["PreToolUse"]?.flatMap {
            $0["hooks"] as? [[String: Any]] ?? []
        }.compactMap { $0["command"] as? String }.first(where: { $0.contains("readiness-event") }))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "CMUX_CLAUDE_HOOK_CMUX_BIN": "/not-the-owned-cli"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let args = try String(contentsOfFile: cli.path + ".args", encoding: .utf8)
        #expect(args.split(separator: "\n").map(String.init) == [
            "hooks", "claude", "readiness-event", "PreToolUse", "--launch", fixture.launch.uuidString
        ])
    }

    @Test func resumeStripsTheOldGuardReceiptButRetainsUserSettings() throws {
        let fixture = try SettingsFixture()
        let upgraded = try fixture.upgrade()
        let argv = try #require(AgentResumeArgv().builtInKind(
            kind: "claude", sessionId: "s", executablePath: "/opt/bin/claude",
            arguments: ["/opt/bin/claude", "--settings", String(decoding: upgraded, as: UTF8.self)]
        ))
        let index = try #require(argv.firstIndex(of: "--settings"))
        let settings = try #require(JSONSerialization.jsonObject(
            with: Data(argv[index + 1].utf8)
        ) as? [String: Any])
        #expect(settings["effortLevel"] as? String == "high")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        #expect(!text.contains(fixture.launch.uuidString))
        #expect(!text.contains("readiness-event"))
    }
}

private struct SettingsFixture {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "Stop", "StopFailure"]
    let launch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let cli: String
    let base: Data
    let final: Data
    let userCommand = "printf 'user-owned hooks enqueue claude prompt-submit' >/dev/null"

    init(cli: String = "/opt/cmux/bin/cmux") throws {
        self.cli = cli
        let subcommands = ["SessionStart": "session-start", "SessionEnd": "session-end",
                           "UserPromptSubmit": "prompt-submit", "PreToolUse": "pre-tool-use",
                           "Stop": "stop", "StopFailure": "stop"]
        var hooks: [String: [[String: Any]]] = [:]
        for event in Self.events {
            let subcommand = subcommands[event]!
            hooks[event] = [[
                "matcher": "", "hooks": [[
                    "type": "command", "timeout": 5,
                    "command": AgentHookSpoolProducer(agent: "claude").command(
                        subcommand: subcommand, fallback: "cmux hooks enqueue claude \(subcommand)"
                    )
                ]]
            ]]
        }
        hooks["PreToolUse", default: []].insert([
            "matcher": "CronCreate",
            "hooks": [["type": "command", "timeout": 5, "command": "cmux hooks claude cron-create-guard"]]
        ], at: 0)
        hooks["PermissionRequest"] = [[
            "matcher": "", "hooks": [["type": "command", "timeout": 125,
                                      "command": "cmux hooks feed --source claude"]]
        ]]
        let managed: [String: Any] = [
            "__cmux": ["managed": "claude-hooks", "version": 1, "shepherdReadiness": 2,
                       "shepherdQualifiedExecutables": [String]()],
            "hooks": hooks, "preferredNotifChannel": "notifications_disabled",
        ]
        base = try JSONSerialization.data(withJSONObject: managed)
        hooks["Stop", default: []].append([
            "matcher": "", "hooks": [["type": "command", "timeout": 5, "command": userCommand]]
        ])
        var merged = managed
        merged["hooks"] = hooks
        merged["effortLevel"] = "high"
        final = try JSONSerialization.data(withJSONObject: merged)
    }

    func upgrade() throws -> Data {
        try ShepherdHookSettings.upgrade(
            settings: final, managedSettings: base, launchID: launch, cliPath: cli
        )
    }
}
#endif
