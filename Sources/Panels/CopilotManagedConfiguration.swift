import Foundation

/// Fixed empty-domain inventories, not provider qualification or permission to send input.
enum CopilotManagedConfiguration {
    static let foregroundToolName = "cmux_run_foreground"
    static let foregroundDescription = "Run one foreground command with the native project authority. No terminal, background work, stdin, directory, environment or timeout overrides."
    static var foregroundSchema: [String: Any] {
        [
            "type": "object", "properties": [
                "program": ["type": "string"], "arguments": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["program", "arguments"], "additionalProperties": false,
        ]
    }
    static var foregroundTool: [String: Any] {
        [
            "name": foregroundToolName, "description": foregroundDescription, "parameters": foregroundSchema,
            "isTerminal": false, "overridesBuiltInTool": false, "skipPermission": true,
        ]
    }

    static func createParameters(
        sessionID: String, workingDirectory: String, nativeForegroundTool: Bool = false
    ) -> [String: Any] {
        [
            "sessionId": sessionID, "workingDirectory": workingDirectory,
            "enableConfigDiscovery": false, "enableSkills": false, "enableFileHooks": false,
            "availableTools": nativeForegroundTool ? ["custom:\(foregroundToolName)"] : [],
            "excludedTools": [], "toolFilterPrecedence": "excluded",
            "tools": nativeForegroundTool ? [foregroundTool] : [], "mcpServers": [:], "customAgents": [],
            "requestPermission": true, "streaming": true, "includeSubAgentStreamingEvents": true,
            "enableSessionTelemetry": false, "mcpOAuthTokenStorage": "in-memory",
            "skipEmbeddingRetrieval": true, "embeddingCacheStorage": "in-memory",
            "enableOnDemandInstructionDiscovery": false, "enableHostGitOperations": false,
            "enableSessionStore": false, "enableGitHubCacheStore": false,
            "memory": ["enabled": false], "customAgentsLocalOnly": true,
            "isExperimentalMode": false, "infiniteSessions": ["enabled": false],
            "additionalDirectories": [], "skillDirectories": [], "agentDirectories": [],
            "instructionDirectories": [], "hookDirectories": [], "pluginDirectories": [],
            "systemMessage": [
                "mode": "customize", "sections": ["environment_context": ["action": "remove"]],
            ],
        ]
    }

    static func optionParameters(sessionID: String, nativeForegroundTool: Bool = false) -> [String: Any] {
        [
            "sessionId": sessionID, "skipCustomInstructions": true,
            "customAgentsLocalOnly": true, "coauthorEnabled": false, "manageScheduleEnabled": false,
            "installedPlugins": [], "includedBuiltinSkills": [], "includedBuiltinAgents": [],
            "availableTools": nativeForegroundTool ? ["custom:\(foregroundToolName)"] : [],
            "excludedTools": [], "toolFilterPrecedence": "excluded",
            "sessionCapabilities": [], "continueOnAutoMode": false,
            "enableSkills": false, "enableFileHooks": false, "enableHostGitOperations": false,
            "enableSessionStore": false, "skipEmbeddingRetrieval": true,
            "enableOnDemandInstructionDiscovery": false,
            "skillDirectories": [], "agentDirectories": [], "instructionDirectories": [], "hookDirectories": [],
        ]
    }

    enum Readback: String, CaseIterable {
        case initializeTools, agents, currentAgent, mcp, plugins, extensions, tools

        var method: String {
            switch self {
            case .agents: "session.agent.list"
            case .currentAgent: "session.agent.getCurrent"
            case .mcp: "session.mcp.listConfigured"
            case .plugins: "session.plugins.list"
            case .extensions: "session.extensions.list"
            case .initializeTools: "session.tools.initializeAndValidate"
            case .tools: "session.tools.getCurrentMetadata"
            }
        }

        func accepts(_ result: [String: Any], nativeForegroundTool: Bool = false) -> Bool {
            if self == .tools && nativeForegroundTool {
                guard Set(result.keys) == ["tools"], let tools = result["tools"] as? [[String: Any]],
                      tools.count == 1, let tool = tools.first,
                      Set(tool.keys) == ["name", "description", "input_schema"],
                      tool["name"] as? String == foregroundToolName,
                      tool["description"] as? String == foregroundDescription,
                      let schema = tool["input_schema"] as? [String: Any] else { return false }
                guard let actual = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
                      let expected = try? JSONSerialization.data(withJSONObject: foregroundSchema, options: [.sortedKeys])
                else { return false }
                return actual == expected
            }
            if self == .initializeTools { return result.isEmpty }
            if self == .currentAgent {
                return Set(result.keys) == ["agent"] && result["agent"] is NSNull
            }
            let key: String
            switch self {
            case .agents: key = "agents"
            case .mcp: key = "servers"
            case .plugins: key = "plugins"
            case .extensions: key = "extensions"
            case .tools: key = "tools"
            case .currentAgent, .initializeTools: return false
            }
            return CopilotManagedConfiguration.acceptsEmptyInventories(result, keys: [key])
        }
    }

    static func acceptsEmptyInventories(_ result: [String: Any], keys: Set<String>) -> Bool {
        Set(result.keys) == keys && keys.allSatisfy { key in
            guard let values = result[key] as? [Any] else { return false }
            return values.isEmpty
        }
    }
}
