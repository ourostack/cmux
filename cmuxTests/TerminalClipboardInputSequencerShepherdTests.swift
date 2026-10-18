import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Guarded clipboard input readiness", .serialized)
struct TerminalClipboardInputSequencerShepherdTests {
    @Test("logical completion and every replay remain unavailable to guarded input")
    func completionAndReplayRetainPendingInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        sequencer.beginRequest(id: 1, epoch: 7)
        #expect(sequencer.shouldDefer("first", epoch: 7))
        #expect(sequencer.shouldDefer("last", epoch: 7))
        var delivered: [String] = []
        var completionWasPending = false
        var replayWasPending: [Bool] = []
        sequencer.completeRequest(
            id: 1,
            confirmed: false,
            onLogicalCompletion: {
                completionWasPending = sequencer.hasPendingInput(for: 7)
            },
            replay: { event in
                replayWasPending.append(sequencer.hasPendingInput(for: 7))
                #expect(!sequencer.shouldDefer(event, epoch: 7))
                delivered.append(event)
            }
        )
        #expect(completionWasPending)
        #expect(replayWasPending == [true, true])
        #expect(delivered == ["first", "last"])
        #expect(!sequencer.hasPendingInput(for: 7))
    }

    @Test("nested empty completions cannot reopen their outer completion")
    func nestedCompletionsRetainPendingInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        sequencer.beginRequest(id: 1, epoch: 7)
        var pending: [Bool] = []
        sequencer.completeRequest(
            id: 1,
            confirmed: false,
            onLogicalCompletion: {
                pending.append(sequencer.hasPendingInput(for: 7))
                sequencer.beginRequest(id: 2, epoch: 7)
                sequencer.completeRequest(
                    id: 2,
                    confirmed: false,
                    onLogicalCompletion: {
                        pending.append(sequencer.hasPendingInput(for: 7))
                    },
                    replay: { _ in Issue.record("No input was buffered.") }
                )
                pending.append(sequencer.hasPendingInput(for: 7))
            },
            replay: { _ in Issue.record("No input was buffered.") }
        )
        #expect(pending == [true, true, true])
        #expect(!sequencer.hasPendingInput(for: 7))
    }

    @Test("cancel replay holds readiness through its final event")
    func cancellationReplayRetainsPendingInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        sequencer.beginRequest(id: 1, epoch: 7)
        #expect(sequencer.shouldDefer("last", epoch: 7))
        var delivered: [String] = []
        var pending = false
        sequencer.cancelRequest(
            id: 1,
            currentEpoch: 7,
            deferredInputDisposition: .replay
        ) { event in
            pending = sequencer.hasPendingInput(for: 7)
            delivered.append(event)
        }
        #expect(pending)
        #expect(delivered == ["last"])
        #expect(!sequencer.hasPendingInput(for: 7))
    }

    @Test("pending readiness is epoch-bound and does not block OSC reads")
    func readinessRemainsScopedToInputWork() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        sequencer.beginUnsequencedRequest(id: 1, epoch: 7)
        #expect(!sequencer.hasPendingInput(for: 7))
        #expect(sequencer.reserveRequestAdmission(id: 2, epoch: 9, onOverflow: {}))
        #expect(sequencer.hasPendingInput(for: 9))
        #expect(!sequencer.hasPendingInput(for: 7))
        sequencer.beginReservedRequest(id: 2)
        #expect(sequencer.hasPendingInput(for: 9))
        sequencer.cancelRequest(
            id: 2, currentEpoch: 9, deferredInputDisposition: .discard,
            replay: { _ in Issue.record("No input was buffered.") }
        )
        #expect(!sequencer.hasPendingInput(for: 9))
    }
}
