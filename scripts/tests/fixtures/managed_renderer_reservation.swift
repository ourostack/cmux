internal import Darwin
import Foundation

@main
struct ManagedRendererReservationFixture {
    enum Failure: Error { case assertion(String) }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure.assertion("missing scenario") }
            try await run(CommandLine.arguments[1])
            print("passed")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run(_ scenario: String) async throws {
        let began = ContinuousClock.now
        var now = began
        var currentHost = true
        var revokeDuringHostCheck: (() -> Void)?
        let gate = AgentSessionManagedRendererReservation(
            isCurrentHost: {
                revokeDuringHostCheck?()
                return currentHost
            }, now: { now }
        )
        let receipt = AgentSessionManagedRendererReservation.Receipt(
            leaseID: "controlled-js-lease", render: "controlled-current-render"
        )
        if scenario == "reentrant-begin" {
            revokeDuringHostCheck = { gate.invalidate() }
            try check(gate.begin() == nil, "revocation during admission minted a ticket")
            return
        }
        guard let ticket = gate.begin() else { throw Failure.assertion("missing native ticket") }
        try check(gate.begin() == nil, "concurrent native reservation")
        if scenario == "pending-invalidation" {
            currentHost = false
            try check(!gate.didInsert(ticket, receipt: receipt), "lost host accepted insertion")
            currentHost = true
            try check(!gate.didInsert(ticket, receipt: receipt), "restored host revived old insertion")
            return
        }
        try check(gate.didInsert(ticket, receipt: receipt), "insertion rejected")
        if scenario == "clock-and-receipt" {
            now = began.advanced(by: .milliseconds(149))
            try check(!gate.didValidate(ticket, receipt: receipt, rendererConfirmed: true), "early submit admitted")
            now = began.advanced(by: .milliseconds(150))
            try check(gate.didValidate(ticket, receipt: receipt, rendererConfirmed: true), "150ms boundary refused")
            guard let frame = gate.claimFrame(ticket) else { throw Failure.assertion("missing guarded frame") }
            try check(frame.validate(), "current frame refused")
            try check(gate.claimFrame(ticket) == nil, "frame claimed twice")
            now = began.advanced(by: .seconds(2))
            try check(!frame.validate(), "2s expiry admitted")
            guard let next = gate.begin() else { throw Failure.assertion("expired reservation still occupied") }
            try check(!gate.didValidate(ticket, receipt: receipt, rendererConfirmed: true), "old ticket revived")
            try check(gate.didInsert(next, receipt: receipt), "stale ticket invalidated fresh reservation")
            gate.invalidate()
            try check(!gate.didValidate(next, receipt: receipt, rendererConfirmed: true), "revoked generation revived")
            return
        }
        now = began.advanced(by: .milliseconds(150))
        try check(gate.didValidate(ticket, receipt: receipt, rendererConfirmed: true), "renderer validation rejected")
        guard let frame = gate.claimFrame(ticket) else { throw Failure.assertion("missing guarded frame") }
        if scenario == "reentrant-host-revocation" {
            revokeDuringHostCheck = { gate.invalidate() }
            try check(!frame.validate(), "reentrant host revocation admitted a frame")
            return
        }
        if scenario == "expiry-during-host-check" {
            revokeDuringHostCheck = { now = began.advanced(by: .seconds(2)) }
            try check(!frame.validate(), "expiry during validation admitted a frame")
            return
        }
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        defer {
            try? writer.close()
            try? pipe.fileHandleForReading.close()
        }
        if scenario == "before-first-byte" {
            currentHost = false
            let result = await writer.write(Data("must not write".utf8), deadline: frame.deadline, validate: frame.validate)
            try check(result == .notWritten(.guardInvalidated), "lost focus admitted a pipe byte")
            return
        }
        guard scenario == "during-backpressure" else { throw Failure.assertion("unknown scenario") }
        let bytes = Data(repeating: 65, count: 256 * 1024)
        let write = Task { await writer.write(bytes, deadline: frame.deadline, validate: frame.validate) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !writer.isAwaitingWritable {
            try check(ContinuousClock.now < deadline, "controlled pipe did not reach backpressure")
            await Task.yield()
        }
        gate.invalidate()
        let result = await write.value
        guard case .partial(let count, .guardInvalidated) = result else {
            throw Failure.assertion("invalidation did not stop partial write: \(result)")
        }
        try check(count > 0 && count < bytes.count, "incorrect partial byte count")
        try check(writer.streamIsTainted, "partial write uncertainty was lost")
    }
}
