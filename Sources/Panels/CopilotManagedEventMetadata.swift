import CoreFoundation
import Foundation

enum CopilotManagedEventMetadata {
    private static let requiredKeys: Set<String> = ["id", "type", "data", "parentId", "timestamp"]
    private static let allowedKeys = requiredKeys.union(["agentId", "ephemeral"])
    private static let transientKinds: Set<String> = [
        "session.idle", "assistant.idle", "assistant.intent", "assistant.message_start",
        "assistant.message_delta", "assistant.reasoning_delta", "session.tools_updated",
        "session.skills_loaded", "session.custom_agents_updated", "session.mcp_servers_loaded",
        "session.extensions_loaded",
    ]

    static func eventID(_ event: [String: Any]) -> UUID? {
        let keys = Set(event.keys)
        guard requiredKeys.isSubset(of: keys), keys.isSubset(of: allowedKeys),
              let id = uuidV4(event["id"]), let kind = event["type"] as? String, !kind.isEmpty,
              event["data"] is [String: Any], isTimestamp(event["timestamp"]),
              event["parentId"] is NSNull || uuidV4(event["parentId"]) != nil,
              event["agentId"] == nil || event["agentId"] is String,
              event["ephemeral"] == nil || boolean(event["ephemeral"]) != nil else { return nil }
        guard !transientKinds.contains(kind) || boolean(event["ephemeral"]) == true else { return nil }
        return id
    }

    static func uuidV4(_ value: Any?) -> UUID? {
        guard let text = value as? String, let id = UUID(uuidString: text),
              id.uuid.6 & 0xf0 == 0x40, id.uuid.8 & 0xc0 == 0x80 else { return nil }
        return id
    }

    static func isTimestamp(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
