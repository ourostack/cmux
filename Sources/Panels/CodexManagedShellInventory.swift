import CoreFoundation
import Foundation

/// One revision-bound shell inventory, not a total-work registry or input-admission capability.
struct CodexManagedShellInventory {
    private struct Pending {
        let id: CodexManagedStreamDecoder.RequestID
        var written = false
        var response: CodexManagedStreamDecoder.Message?
    }

    private let threadID: String
    private let eventRevision: UUID
    private var pending: Pending?
    private var nextCursor: String?
    private var requestIDs: Set<CodexManagedStreamDecoder.RequestID> = []
    private var cursors: Set<String> = []
    private var itemIDs: Set<String> = []
    private var processIDs: Set<String> = []
    private var retainedBytes = 0
    private var completed = false
    private(set) var failureReason: String?
    private(set) var terminals: [[String: Any]] = []

    var isComplete: Bool { failureReason == nil && completed }
    var hasEmptyCompleteSnapshot: Bool { isComplete && terminals.isEmpty }

    init(threadID: String, eventRevision: UUID) {
        self.threadID = threadID
        self.eventRevision = eventRevision
        if threadID.isEmpty || threadID.utf8.count > 4096 { failureReason = "invalidScope" }
    }

    mutating func requestNextPage(
        id: CodexManagedStreamDecoder.RequestID, currentRevision: UUID
    ) -> [String: Any]? {
        guard failureReason == nil else { return nil }
        guard currentRevision == eventRevision, !completed, pending == nil,
              CodexManagedStreamDecoder.RequestID(jsonValue: id.jsonValue) == id,
              requestIDs.count < 64, requestIDs.insert(id).inserted else {
            fail("pageRequestMismatch")
            return nil
        }
        pending = Pending(id: id)
        return [
            "id": id.jsonValue, "method": "thread/backgroundTerminals/list",
            "params": ["threadId": threadID, "cursor": nextCursor.map { $0 as Any } ?? NSNull(), "limit": 128],
        ]
    }

    mutating func pageWritten(id: CodexManagedStreamDecoder.RequestID, currentRevision: UUID) -> Bool {
        guard failureReason == nil else { return false }
        guard currentRevision == eventRevision, var page = pending, page.id == id, !page.written else {
            return fail("pageWriteMismatch")
        }
        page.written = true
        pending = page
        return consumePageIfPossible()
    }

    mutating func receive(_ message: CodexManagedStreamDecoder.Message, currentRevision: UUID) -> Bool {
        guard failureReason == nil else { return false }
        guard currentRevision == eventRevision, var page = pending,
              message.kind == .response, message.id == page.id, page.response == nil else {
            return fail("pageResponseMismatch")
        }
        page.response = message
        pending = page
        return consumePageIfPossible()
    }

    private mutating func consumePageIfPossible() -> Bool {
        guard let page = pending, page.written, let response = page.response else { return true }
        guard let result = response.object["result"] as? [String: Any],
              Set(result.keys) == ["data", "nextCursor"],
              let records = result["data"] as? [[String: Any]], records.count <= 128,
              records.count <= 1024 - terminals.count else { return fail("invalidPage") }
        let cursor: String?
        if result["nextCursor"] is NSNull {
            cursor = nil
        } else if let value = result["nextCursor"] as? String,
                  !value.isEmpty, value.utf8.count <= 4096, cursors.insert(value).inserted {
            cursor = value
        } else {
            return fail("invalidCursor")
        }
        for record in records {
            guard Set(record.keys) == ["itemId", "processId", "command", "cwd", "osPid", "cpuPercent", "rssKb"],
                  let itemID = record["itemId"] as? String, !itemID.isEmpty, itemID.utf8.count <= 4096,
                  let processID = record["processId"] as? String, !processID.isEmpty, processID.utf8.count <= 4096,
                  let command = record["command"] as? String, command.utf8.count <= 256 * 1024,
                  let cwd = record["cwd"] as? String, cwd.utf8.count <= 4096,
                  optionalUnsignedInteger(record["osPid"], maximum: UInt64(UInt32.max)),
                  optionalUnsignedInteger(record["rssKb"], maximum: UInt64.max),
                  optionalCPUPercent(record["cpuPercent"]),
                  itemIDs.insert(itemID).inserted, processIDs.insert(processID).inserted else {
                return fail("invalidTerminal")
            }
            let bytes = itemID.utf8.count + processID.utf8.count + command.utf8.count + cwd.utf8.count
            guard bytes <= 2 * 1024 * 1024 - retainedBytes else { return fail("inventoryTooLarge") }
            retainedBytes += bytes
            terminals.append(record)
        }
        pending = nil
        nextCursor = cursor
        completed = cursor == nil
        return true
    }

    private func optionalUnsignedInteger(_ value: Any?, maximum: UInt64) -> Bool {
        if value is NSNull { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
                .contains(String(cString: number.objCType)),
              let integer = UInt64(number.stringValue) else { return false }
        return integer <= maximum
    }

    private func optionalCPUPercent(_ value: Any?) -> Bool {
        if value is NSNull { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }

    @discardableResult
    private mutating func fail(_ reason: String) -> Bool {
        if failureReason == nil { failureReason = reason }
        return false
    }
}
