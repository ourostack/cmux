import CoreFoundation
import CryptoKit
import Foundation

/// The private startup boundary; not a native profile qualification.
struct CodexManagedStartup {
    static let profileSHA256 = "5dd7978748e6bee503ee1ccf593181fc46c058843fc0943daee191898885ca8f"
    static let catalogSHA256 = "c21244950ae26f4e029cf91d9c3d85ff1691c83292ab91627bb528cfe0d7e0a9"
    static func sourceManifest() throws -> Data {
        let json = #"""
        {
          "catalogSha256":"c21244950ae26f4e029cf91d9c3d85ff1691c83292ab91627bb528cfe0d7e0a9",
          "commandAuthority":{"activation":"fresh-native-panel-opt-in","authority":"native-user-project","execution":"general-purpose-foreground","rpcActivationAllowed":false,"sdkApprovalPrompt":false,"sdkSandbox":false},
          "commandSchemaSha256":"65e90ae9b000d5bd8d9c345706abaa94191afd6aee3a66b3bf29556c390183e6",
          "integrationPatchSha256":"fe327838f4e4c909d41eb36ec9d34b702ab87bec7ff7cb8c488064cc84ab8922",
          "nativeTool":{"description":"Run one foreground command with the native project authority. No terminal, background work, stdin, directory, environment or timeout overrides.","inputSchema":{"additionalProperties":false,"properties":{"arguments":{"items":{"type":"string"},"type":"array"},"program":{"type":"string"}},"required":["program","arguments"],"type":"object"},"name":"cmux_run_foreground","type":"function"},
          "privateBridgeVersion":1,
          "profileId":"codex-0.154-frozen-native-foreground-v1",
          "startupOptions":{"channelCapacity":1,"enableCodexApiKeyEnv":false,"initialize":{"capabilities":{"experimentalApi":true,"optOutNotificationMethods":null,"requestAttestation":false},"clientInfo":{"name":"cmux-managed-codex-host","title":null,"version":"0.1.0"}},"sessionSource":{"custom":"cmux"}},
          "threadOptions":{"approvalPolicy":null,"approvalsReviewer":null,"baseInstructions":null,"config":null,"cwd":null,"developerInstructions":null,"dynamicTools":[{"description":"Run one foreground command with the native project authority. No terminal, background work, stdin, directory, environment or timeout overrides.","inputSchema":{"additionalProperties":false,"properties":{"arguments":{"items":{"type":"string"},"type":"array"},"program":{"type":"string"}},"required":["program","arguments"],"type":"object"},"name":"cmux_run_foreground","type":"function"}],"environments":[],"ephemeral":null,"historyMode":null,"mockExperimentalField":null,"model":null,"modelProvider":null,"multiAgentMode":null,"permissions":null,"personality":null,"projectId":null,"runtimeWorkspaceRoots":null,"sandbox":null,"selectedCapabilityRoots":[],"serviceName":null,"sessionStartSource":null,"threadSource":null},
          "turnOptions":{"additionalContext":null,"approvalPolicy":null,"approvalsReviewer":null,"clientUserMessageId":null,"collaborationMode":null,"cwd":null,"cyberAccessProgram":null,"effort":null,"environments":[],"model":null,"multiAgentMode":null,"outputSchema":null,"permissions":null,"personality":null,"responsesapiClientMetadata":null,"runtimeWorkspaceRoots":null,"sandboxPolicy":null,"serviceTierForTurn":null,"summary":null,"toolOutput":null,"turnTrigger":null},
          "upstreamCommit":"6b9826e3aa83b1a5947db50f4332cb9c65f1b340"
        }
        """#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == profileSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
    private static let features: Set<String> = [
        "multi_agent_v2", "goals", "memories", "guardian_approval", "sleep_tool",
        "code_mode", "code_mode_only", "code_mode_prewarm", "hooks",
        "web_search_request", "web_search_cached", "image_generation", "apps", "plugins",
        "skill_mcp_dependency_install", "skill_search",
    ]
    private enum Phase { case descriptor, descriptorObserved, initializeIssued, ready, held }
    private let nonce: String
    private let workingDirectory: String
    private var phase: Phase = .descriptor
    private var decoder = CodexManagedStreamDecoder()
    private var receivedBytes = 0
    private var initializeID: String?
    private var initializeWasWritten = false
    private var readyResponse: [String: Any]?
    private(set) var failureReason: String?
    private(set) var threadID: String?
    private(set) var profileManifest: Data?
    var configurationObserved: Bool { phase == .ready && failureReason == nil && !decoder.hasPendingBytes }

    init(bootNonce: UUID, workingDirectory: String) {
        self.nonce = bootNonce.uuidString.lowercased()
        self.workingDirectory = workingDirectory
        if nonce == "00000000-0000-0000-0000-000000000000"
            || !workingDirectory.hasPrefix("/") || workingDirectory.utf8.contains(0) {
            fail("invalidStartupBirth")
        }
    }

    mutating func receive(_ bytes: Data) {
        guard failureReason == nil else { return }
        guard bytes.count <= 2 * 1_048_576 - receivedBytes else {
            fail("startupBytesExceeded")
            return
        }
        receivedBytes += bytes.count
        do {
            for message in try decoder.append(bytes) {
                guard failureReason == nil, message.wireByteCount <= 1_048_576 else {
                    fail("startupFrameExceeded")
                    return
                }
                switch phase {
                case .descriptor:
                    guard let profile = validateDescriptor(message) else {
                        fail("descriptorMismatch")
                        return
                    }
                    profileManifest = profile
                    phase = .descriptorObserved
                case .initializeIssued:
                    guard readyResponse == nil, message.kind == .response,
                          message.id == initializeID.map(CodexManagedStreamDecoder.RequestID.string),
                          let response = message.object["result"] as? [String: Any],
                          validReady(response) else {
                        fail("initializationMismatch")
                        return
                    }
                    readyResponse = response
                case .descriptorObserved, .ready, .held:
                    fail("unexpectedStartupIngress")
                    return
                }
            }
        } catch {
            fail("invalidStartupStream:\(error)")
        }
        commitReadyIfPossible()
    }

    mutating func initializeFrame() -> Data? {
        guard failureReason == nil, phase == .descriptorObserved, !decoder.hasPendingBytes else { return nil }
        let id = "cmux-init-" + UUID().uuidString.lowercased()
        do {
            let frame = try JSONSerialization.data(withJSONObject: [
                "id": id, "method": "cmux/initialize",
                "params": ["bootNonce": nonce, "profileDigest": Self.profileSHA256],
            ], options: [.sortedKeys, .withoutEscapingSlashes]) + Data([0x0A])
            initializeID = id
            phase = .initializeIssued
            return frame
        } catch {
            fail("initializeEncodingFailed")
            return nil
        }
    }

    mutating func initializeWritten() -> Bool {
        guard failureReason == nil else { return false }
        guard phase == .initializeIssued, !initializeWasWritten else {
            fail("initializeWriteMismatch")
            return false
        }
        initializeWasWritten = true
        commitReadyIfPossible()
        return failureReason == nil
    }

    mutating func finishStream() {
        guard failureReason == nil else { return }
        do { try decoder.finish() }
        catch {
            fail("invalidStartupEOF:\(error)")
            return
        }
        fail("startupStreamEnded")
    }

    private func validateDescriptor(_ message: CodexManagedStreamDecoder.Message) -> Data? {
        guard message.kind == .notification,
              Set(message.object.keys) == ["method", "params"],
              message.object["method"] as? String == "cmux/codex/descriptor",
              let params = message.object["params"] as? [String: Any],
              Set(params.keys) == ["bootNonce", "cwd", "storeId", "profileDigest", "profile", "effective"],
              params["bootNonce"] as? String == nonce, params["cwd"] as? String == workingDirectory,
              params["storeId"] as? String == "cmux-" + nonce,
              params["profileDigest"] as? String == Self.profileSHA256,
              let profile = params["profile"] as? [String: Any],
              Self.integer(profile["privateBridgeVersion"], equals: 1),
              let startup = profile["startupOptions"] as? [String: Any],
              Self.integer(startup["channelCapacity"], equals: 1),
              let bytes = try? JSONSerialization.data(
                  withJSONObject: profile, options: [.sortedKeys, .withoutEscapingSlashes]),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == Self.profileSHA256,
              let effective = params["effective"] as? [String: Any],
              validEffective(effective) else { return nil }
        return bytes
    }

    private func validEffective(_ value: [String: Any]) -> Bool {
        guard Set(value.keys) == [
            "model", "modelProviderId", "ephemeral", "agentsEnabled", "approvalPolicy", "webSearch",
            "features", "toolModesByAvailability", "catalogSha256", "modelExperimentalTools",
            "modelMultiAgentVersion", "mcpServerCount", "legacyNotifyCount",
            "orchestratorSkillsEnabled", "orchestratorMcpEnabled", "generateMemories", "useMemories",
            "dedicatedMemoryTools", "historyNotes", "threadStore",
        ], value["model"] as? String == "gpt-5.5", value["modelProviderId"] as? String == "openai",
              Self.boolean(value["ephemeral"], equals: true),
              value["approvalPolicy"] as? String == "never", value["webSearch"] as? String == "disabled",
              value["catalogSha256"] as? String == Self.catalogSHA256,
              value["modelMultiAgentVersion"] as? String == "disabled",
              let tools = value["modelExperimentalTools"] as? [Any], tools.isEmpty,
              value["toolModesByAvailability"] as? [[String]] == [["direct", "direct"], ["direct", "direct"]],
              Self.integer(value["mcpServerCount"], equals: 0),
              Self.integer(value["legacyNotifyCount"], equals: 0),
              let features = value["features"] as? [String: Any], Set(features.keys) == Self.features,
              Self.features.allSatisfy({ Self.boolean(features[$0], equals: false) }),
              let store = value["threadStore"] as? [String: Any], Set(store.keys) == ["type", "id"],
              store["type"] as? String == "inMemory", store["id"] as? String == "cmux-" + nonce else {
            return false
        }
        return [
            "agentsEnabled", "orchestratorSkillsEnabled", "orchestratorMcpEnabled",
            "generateMemories", "useMemories", "dedicatedMemoryTools", "historyNotes",
        ].allSatisfy { Self.boolean(value[$0], equals: false) }
    }

    private func validReady(_ value: [String: Any]) -> Bool {
        guard Set(value.keys) == [
            "thread", "model", "modelProvider", "serviceTier", "cwd", "runtimeWorkspaceRoots",
            "instructionSources", "approvalPolicy", "approvalsReviewer", "sandbox",
            "activePermissionProfile", "reasoningEffort", "multiAgentMode",
        ], value["model"] as? String == "gpt-5.5", value["modelProvider"] as? String == "openai",
              value["cwd"] as? String == workingDirectory, value["approvalPolicy"] as? String == "never",
              value["multiAgentMode"] as? String == "explicitRequestOnly",
              value["runtimeWorkspaceRoots"] is [String], value["instructionSources"] is [String],
              let sandbox = value["sandbox"] as? [String: Any], Set(sandbox.keys) == ["type"],
              sandbox["type"] as? String == "dangerFullAccess",
              let thread = value["thread"] as? [String: Any],
              Set(thread.keys).isSubset(of: [
                  "id", "environments", "extra", "sessionId", "forkedFromId", "parentThreadId",
                  "preview", "ephemeral", "section", "sectionEnteredAt", "projectId", "historyMode",
                  "modelProvider", "model", "reasoningEffort", "createdAt", "updatedAt", "recencyAt",
                  "status", "path", "cwd", "cliVersion", "originator", "source", "canAcceptDirectInput",
                  "threadSource", "agentNickname", "agentRole", "gitInfo", "name", "daybreakEnabled", "turns",
              ]),
              let id = thread["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let sessionID = thread["sessionId"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 128,
              thread["cwd"] as? String == workingDirectory,
              thread["modelProvider"] as? String == "openai",
              Self.boolean(thread["ephemeral"], equals: true),
              thread["cliVersion"] as? String == "0.154.0",
              let turns = thread["turns"] as? [Any], turns.isEmpty else { return false }
        for field in ["forkedFromId", "parentThreadId", "agentNickname", "agentRole"] {
            guard thread[field] is NSNull else { return false }
        }
        return true
    }

    private mutating func commitReadyIfPossible() {
        guard failureReason == nil, phase == .initializeIssued, initializeWasWritten,
              !decoder.hasPendingBytes, let response = readyResponse,
              let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else { return }
        threadID = id
        phase = .ready
    }

    private mutating func fail(_ reason: String) {
        guard failureReason == nil else { return }
        failureReason = reason
        phase = .held
        threadID = nil
    }

    private static func boolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }

    private static func integer(_ value: Any?, equals expected: Int64) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let integer = Int64(number.stringValue) else { return false }
        return integer == expected
    }
}
