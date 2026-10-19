import CmuxControlSocket
import Foundation

@MainActor
final class CopilotManagedSession {
    enum Phase: String {
        case idle, connecting, creating, configuring, awaitingReadback, held
    }

    let sessionID = UUID().uuidString.lowercased()
    private(set) var phase: Phase = .idle
    private(set) var holdReason: String?
    private(set) var bufferedEvents: [Data] = []

    init(
        lifetime: AgentSessionManagedSession, takingOwnershipOf input: FileHandle,
        workingDirectory: String
    ) throws {}

    func start(launchID: UUID) {
        phase = .held
        holdReason = "startupUnavailable"
    }
}
