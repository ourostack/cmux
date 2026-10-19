#if SHEPHERD_SOURCE_TEST
import CmuxTerminal
import Foundation
import Testing

@Suite(.serialized) @MainActor struct ShepherdInputReservationTests {
    @Test func ownedPasteRetainsBaseRevisionAcrossRepeatedReadsAndOnlyOneSubmit() throws {
        let surface = TerminalSurface(workspaceID: UUID())
        surface.shepherdInputRevision = 9
        let request = UUID()
        let admitted = surface.sendShepherdPaste(
            "Continue.", requestID: request, expiresAt: ProcessInfo.processInfo.systemUptime + 1
        )
        #expect(admitted == 10)
        #expect(surface.shepherdReadinessObservationRevision == 9)
        #expect(surface.shepherdReadinessObservationRevision == 9)
        #expect(surface.hasShepherdInputReservation)
        #expect(surface.sendShepherdPaste(
            "Again.", requestID: UUID(), expiresAt: ProcessInfo.processInfo.systemUptime + 1
        ) == nil)
        #expect(surface.pastes == ["Continue."])
        var revisionDuringEnter: UInt64?
        surface.onWrite = { revisionDuringEnter = surface.shepherdReadinessObservationRevision }
        #expect(surface.sendShepherdSubmit(requestID: request))
        #expect(revisionDuringEnter == 11)
        #expect(!surface.sendShepherdSubmit(requestID: request))
        #expect(surface.submits.count == 1)
        #expect(surface.shepherdReadinessObservationRevision == 11)
    }

    @Test(arguments: ["physical", "generation", "revision", "release", "expiry"])
    func changedEpochNeverLendsOldReadinessToAnotherWrite(change: String) async {
        let surface = TerminalSurface(workspaceID: UUID())
        surface.shepherdInputRevision = 9
        let request = UUID()
        #expect(surface.sendShepherdPaste(
            "Continue.", requestID: request, expiresAt: ProcessInfo.processInfo.systemUptime + 0.03
        ) == 10)
        switch change {
        case "physical": surface.invalidateShepherdInput()
        case "generation": surface.runtimeSurfaceGeneration += 1
        case "revision": surface.shepherdInputRevision += 1
        case "release": surface.finishShepherdInputReservation(requestID: request)
        default: try? await Task.sleep(for: .milliseconds(60))
        }
        #expect(surface.shepherdReadinessObservationRevision != 9)
        #expect(!surface.sendShepherdSubmit(requestID: request))
        #expect(surface.submits.isEmpty)
    }
}
#endif
