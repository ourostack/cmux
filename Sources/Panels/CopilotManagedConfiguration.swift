import Foundation

/// Fixed empty-domain inventories, not provider qualification or permission to send input.
enum CopilotManagedConfiguration {
    static func createParameters(sessionID: String, workingDirectory: String) -> [String: Any] {
        [
            "sessionId": sessionID, "workingDirectory": workingDirectory,
            "enableConfigDiscovery": false, "enableSkills": false, "enableFileHooks": false,
            "availableTools": [], "excludedTools": [], "toolFilterPrecedence": "excluded",
            "tools": [], "mcpServers": [:], "customAgents": [],
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

    static func optionParameters(sessionID: String) -> [String: Any] {
        [
            "sessionId": sessionID, "skipCustomInstructions": true,
            "customAgentsLocalOnly": true, "coauthorEnabled": false, "manageScheduleEnabled": false,
            "installedPlugins": [], "includedBuiltinSkills": [], "includedBuiltinAgents": [],
            "availableTools": [], "excludedTools": [], "toolFilterPrecedence": "excluded",
            "sessionCapabilities": [], "continueOnAutoMode": false,
            "enableSkills": false, "enableFileHooks": false, "enableHostGitOperations": false,
            "enableSessionStore": false, "skipEmbeddingRetrieval": true,
            "enableOnDemandInstructionDiscovery": false,
            "skillDirectories": [], "agentDirectories": [], "instructionDirectories": [], "hookDirectories": [],
        ]
    }

    enum Readback: String, CaseIterable {
        case agents, currentAgent, mcp, plugins, extensions, initializeTools, tools

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

        func accepts(_ result: [String: Any]) -> Bool {
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
            guard Set(result.keys) == [key], let values = result[key] as? [Any] else { return false }
            return values.isEmpty
        }
    }
}
