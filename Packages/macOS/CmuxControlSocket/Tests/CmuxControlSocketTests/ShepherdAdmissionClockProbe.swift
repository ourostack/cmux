import Foundation

@MainActor
final class ShepherdAdmissionClockProbe {
    var now: TimeInterval = 100
    var waits: [TimeInterval] = []
    var action: (@MainActor (TimeInterval) async throws -> Void)?

    func wait(_ seconds: TimeInterval) async throws {
        waits.append(seconds)
        if let action {
            try await action(seconds)
        } else {
            now += seconds
        }
    }
}
