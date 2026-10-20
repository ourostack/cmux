import CoreFoundation
import Foundation

/// Native custody of renderer evidence; never grants provider or profile authority.
@MainActor
final class AgentSessionManagedRendererController {
    struct Context: Equatable {
        let owner: ObjectIdentifier
        let store: ObjectIdentifier
        let coordinator: ObjectIdentifier
        let host: ObjectIdentifier
        let webView: ObjectIdentifier
        let window: ObjectIdentifier
        let responder: ObjectIdentifier
        let workspaceID: UUID
        let panelID: UUID
        let renderer: String
        let document: String
        let paintGeneration: UInt64
        let geometry: [Double]
    }

    enum Operation {
        case capture
        case reserve(snapshot: [String: String], text: String)
        case validate(receipt: [String: String])
        case release(leaseID: String)
    }

    final class Snapshot {
        let editorText: String
        fileprivate let origin: UUID
        fileprivate let epoch: UInt64
        fileprivate let context: Context
        fileprivate let values: [String: String]

        fileprivate init(origin: UUID, epoch: UInt64, context: Context, values: [String: String]) {
            self.origin = origin
            self.epoch = epoch
            self.context = context
            self.values = values
            editorText = values["editorText"]!
        }
    }

    final class Insertion {
        fileprivate let snapshot: Snapshot
        fileprivate let ticket: AgentSessionManagedRendererReservation.Ticket
        fileprivate let receipt: AgentSessionManagedRendererReservation.Receipt
        fileprivate let inserted: ContinuousClock.Instant
        fileprivate let deadline: ContinuousClock.Instant
        fileprivate var claimed = false

        fileprivate init(
            snapshot: Snapshot, ticket: AgentSessionManagedRendererReservation.Ticket,
            receipt: AgentSessionManagedRendererReservation.Receipt, inserted: ContinuousClock.Instant,
            deadline: ContinuousClock.Instant
        ) {
            self.snapshot = snapshot
            self.ticket = ticket
            self.receipt = receipt
            self.inserted = inserted
            self.deadline = deadline
        }
    }

    private let identity = UUID()
    private var epoch: UInt64 = 0
    private let context: @MainActor () -> Context?
    private let operation: @MainActor (Operation) async throws -> Any?
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async throws -> Void
    private let onReleaseError: @MainActor (Error) -> Void
    private var activeContext: Context?
    private var activeInsertion: Insertion?
    private lazy var reservation = AgentSessionManagedRendererReservation(
        isCurrentHost: { [weak self] in
            guard let self, let expected = self.activeContext else { return false }
            return self.matches(expected, epoch: self.epoch)
        }, now: now
    )

    init(
        context: @escaping @MainActor () -> Context?,
        operation: @escaping @MainActor (Operation) async throws -> Any?,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onReleaseError: @escaping @MainActor (Error) -> Void
    ) {
        self.context = context
        self.operation = operation
        self.now = now
        self.sleep = sleep
        self.onReleaseError = onReleaseError
    }

    func capture() async throws -> Snapshot? {
        if let insertion = activeInsertion, now() >= insertion.deadline { invalidate() }
        guard activeContext == nil else { return nil }
        let epoch = self.epoch
        guard let context = context(), self.epoch == epoch else { return nil }
        do {
            let reply = try await operation(.capture)
            guard matches(context, epoch: epoch),
                  let values = Self.strings(reply, keys: ["editorText", "editVersion", "render"]),
                  Self.bounded(values["editorText"], maximum: 1024 * 1024, allowEmpty: true),
                  Self.bounded(values["editVersion"], maximum: 128),
                  Self.bounded(values["render"], maximum: 1024 * 1024) else { return nil }
            return Snapshot(origin: identity, epoch: epoch, context: context, values: values)
        } catch {
            revokeIfCurrent(epoch)
            throw error
        }
    }

    func insert(_ snapshot: Snapshot, text: String) async throws -> Insertion? {
        guard snapshot.origin == identity, Self.bounded(text, maximum: 256 * 1024),
              activeContext == nil, matches(snapshot.context, epoch: snapshot.epoch) else { return nil }
        activeContext = snapshot.context
        let deadline = now().advanced(by: .seconds(2))
        guard let ticket = reservation.begin() else {
            revokeIfCurrent(snapshot.epoch)
            return nil
        }
        do {
            let reply = try await operation(.reserve(snapshot: snapshot.values, text: text))
            let values = Self.strings(reply, keys: ["leaseId", "render"])
            let receipt = values.flatMap { values -> AgentSessionManagedRendererReservation.Receipt? in
                guard Self.bounded(values["leaseId"], maximum: 128),
                      Self.bounded(values["render"], maximum: 1024 * 1024),
                      let leaseID = values["leaseId"], let render = values["render"] else { return nil }
                return .init(leaseID: leaseID, render: render)
            }
            guard matches(snapshot.context, epoch: snapshot.epoch), let receipt,
                  reservation.didInsert(ticket, receipt: receipt) else {
                revokeIfCurrent(snapshot.epoch)
                if let receipt { release(receipt.leaseID) }
                return nil
            }
            let insertion = Insertion(
                snapshot: snapshot, ticket: ticket, receipt: receipt, inserted: now(), deadline: deadline
            )
            activeInsertion = insertion
            return insertion
        } catch {
            revokeIfCurrent(snapshot.epoch)
            throw error
        }
    }

    func prepareFrame(_ insertion: Insertion) async throws -> AgentSessionManagedRendererReservation.Frame? {
        guard activeInsertion === insertion, !insertion.claimed else { return nil }
        let snapshot = insertion.snapshot
        guard matches(snapshot.context, epoch: snapshot.epoch) else { return nil }
        do {
            let remaining = now().duration(to: insertion.inserted.advanced(by: .milliseconds(150)))
            if remaining > .zero { try await sleep(remaining) }
            guard activeInsertion === insertion, !insertion.claimed,
                  matches(snapshot.context, epoch: snapshot.epoch) else { return nil }
            let reply = try await operation(.validate(receipt: [
                "leaseId": insertion.receipt.leaseID, "render": insertion.receipt.render,
            ]))
            guard activeInsertion === insertion, !insertion.claimed,
                  matches(snapshot.context, epoch: snapshot.epoch),
                  let boolean = reply as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(),
                  reservation.didValidate(insertion.ticket, receipt: insertion.receipt,
                                          rendererConfirmed: boolean.boolValue),
                  let frame = reservation.claimFrame(insertion.ticket) else {
                revokeIfCurrent(snapshot.epoch)
                return nil
            }
            insertion.claimed = true
            return frame
        } catch {
            revokeIfCurrent(snapshot.epoch)
            throw error
        }
    }

    func invalidate() {
        epoch &+= 1
        reservation.invalidate()
        let leaseID = activeInsertion?.receipt.leaseID
        activeInsertion = nil
        activeContext = nil
        if let leaseID { release(leaseID) }
    }

    func finish(_ insertion: Insertion) {
        if activeInsertion === insertion { invalidate() }
    }

    private func matches(_ expected: Context, epoch: UInt64) -> Bool {
        guard self.epoch == epoch else { return false }
        let current = context()
        guard self.epoch == epoch else { return false }
        guard current == expected else {
            invalidate()
            return false
        }
        return true
    }

    private func revokeIfCurrent(_ epoch: UInt64) {
        if self.epoch == epoch { invalidate() }
    }

    private func release(_ leaseID: String) {
        let operation = self.operation
        let onReleaseError = self.onReleaseError
        Task { @MainActor in
            do { _ = try await operation(.release(leaseID: leaseID)) }
            catch { onReleaseError(error) }
        }
    }

    private static func strings(_ value: Any?, keys: Set<String>) -> [String: String]? {
        guard let values = value as? [String: String], Set(values.keys) == keys else { return nil }
        return values
    }

    private static func bounded(_ value: String?, maximum: Int, allowEmpty: Bool = false) -> Bool {
        guard let value else { return false }
        return (allowEmpty || !value.isEmpty) && value.utf8.count <= maximum
    }
}
