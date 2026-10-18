import Foundation
@testable import CmuxControlSocket

@MainActor
final class ShepherdAdmissionHostProbe: ShepherdAdmissionHost {
    var current: ShepherdAdmissionSnapshot? = ShepherdAdmissionSnapshot(
        surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        processInstance: "123:456", surfaceGeneration: 1,
        screenFingerprint: "screen-before", outsideComposerFingerprint: "outside-before",
        inputRevision: 10, focusRevision: 20, focused: false, idle: true,
        composer: .empty, backgroundWork: false, acceptsImmediateInput: true,
        agent: "Copilot", workingDirectory: "/synthetic/project", tty: "/dev/ttys007"
    )
    var pasteCalls = 0
    var submitCalls = 0
    var released: [UUID] = []
    var events: [String] = []
    var lastDeadline: TimeInterval?
    var admitsPaste = true
    var admitsSubmit = true

    func snapshot(workspaceID: UUID, surfaceID: UUID) -> ShepherdAdmissionSnapshot? {
        events.append("read")
        return current
    }

    func paste(
        request: ShepherdContinuationRequest,
        snapshot: ShepherdAdmissionSnapshot,
        expiresAt: TimeInterval
    ) -> ShepherdPasteWriteResult {
        pasteCalls += 1
        events.append("paste")
        lastDeadline = expiresAt
        guard admitsPaste, var next = current else { return .notAdmitted }
        next.inputRevision += 1
        next.composer = .draft(request.text)
        next.screenFingerprint = "own-draft"
        current = next
        return .admitted(inputRevision: next.inputRevision)
    }

    func submit(requestID: UUID, snapshot: ShepherdAdmissionSnapshot) -> Bool {
        submitCalls += 1
        events.append("submit")
        return admitsSubmit
    }

    func releaseReservation(requestID: UUID, snapshot: ShepherdAdmissionSnapshot) {
        released.append(requestID)
        events.append("release")
    }
}
