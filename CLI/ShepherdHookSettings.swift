import CMUXAgentLaunch
import Foundation

struct ShepherdHookSettings {
    private static let events = [
        ("SessionStart", "session-start"), ("SessionEnd", "session-end"),
        ("UserPromptSubmit", "prompt-submit"), ("PreToolUse", "pre-tool-use"),
        ("Stop", "stop"), ("StopFailure", "stop"),
    ]

    static func upgrade(
        settings: Data, managedSettings: Data, launchID: UUID, cliPath: String
    ) throws -> Data {
        guard settings.count <= 1024 * 1024, managedSettings.count <= 1024 * 1024,
              cliPath.hasPrefix("/"), !cliPath.utf8.contains(0),
              var object = try JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let managed = try JSONSerialization.jsonObject(with: managedSettings) as? [String: Any],
              var hooks = object["hooks"] as? [String: [[String: Any]]],
              let baseHooks = managed["hooks"] as? [String: [[String: Any]]],
              var marker = object["__cmux"] as? [String: Any],
              marker["managed"] as? String == "claude-hooks",
              let baseMarker = managed["__cmux"] as? [String: Any],
              baseMarker["managed"] as? String == "claude-hooks",
              baseMarker["shepherdReadiness"] as? Int == 2,
              object["disableAllHooks"] as? Bool != true else {
            throw CLIError(message: "Shepherd hook settings do not establish complete enabled managed coverage.")
        }
        if let existing = marker["shepherdLaunch"] {
            guard let text = existing as? String, UUID(uuidString: text) == launchID else {
                throw CLIError(message: "Shepherd launch settings cannot be rebound to another receipt.")
            }
        }
        var guardedManaged = baseHooks
        let quotedCLI = AgentMoveShellQuoting().quote(cliPath)
        for (event, subcommand) in events {
            guard let baseGroups = baseHooks[event], var groups = hooks[event] else {
                throw CLIError(message: "Shepherd launch settings are missing the \(event) hook.")
            }
            let queued = baseGroups.filter { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("hooks enqueue claude \(subcommand)") == true
                }
            }
            guard queued.count == 1, let original = queued.first else {
                throw CLIError(message: "Shepherd managed \(event) coverage is ambiguous.")
            }
            let originalKey = try canonical(original)
            var hook: [String: Any] = [
                "type": "command", "timeout": 5,
                "command": "exec \(quotedCLI) hooks claude readiness-event \(event) --launch \(launchID.uuidString)",
            ]
            if event == "UserPromptSubmit" || event == "PreToolUse" {
                hook["onFailure"] = "block"
            }
            let replacement: [String: Any] = ["matcher": "", "hooks": [hook]]
            let replacementKey = try canonical(replacement)
            var matching: [Int] = []
            for (index, group) in groups.enumerated() {
                let key = try canonical(group)
                if key == originalKey || key == replacementKey { matching.append(index) }
            }
            guard matching.count == 1, let index = matching.first else {
                throw CLIError(message: "Shepherd launch settings do not have exactly one owned \(event) hook.")
            }
            groups[index] = replacement
            hooks[event] = groups
            guardedManaged[event] = try baseGroups.map {
                try canonical($0) == originalKey ? replacement : $0
            }
        }
        var fingerprints: [String] = []
        for event in guardedManaged.keys.sorted() {
            for group in guardedManaged[event] ?? [] {
                fingerprints.append(try canonical(group))
            }
        }
        marker["shepherdReadiness"] = 2
        marker["shepherdLaunch"] = launchID.uuidString
        marker["hookFingerprints"] = fingerprints
        object["__cmux"] = marker
        object["hooks"] = hooks
        let result = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard result.count <= 1024 * 1024 else {
            throw CLIError(message: "Shepherd guarded settings exceeded the launch artifact size limit.")
        }
        return result
    }

    private static func canonical(_ group: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(
            withJSONObject: group, options: [.sortedKeys, .withoutEscapingSlashes]
        ), as: UTF8.self)
    }
}
