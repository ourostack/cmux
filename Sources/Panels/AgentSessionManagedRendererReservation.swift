import Foundation

/// A native revocation lane for renderer evidence, not a profile or input authorization.
@MainActor
final class AgentSessionManagedRendererReservation {
    struct Receipt: Equatable {
        let leaseID: String
        let render: String
    }

    @MainActor final class Ticket {
        fileprivate let began: ContinuousClock.Instant
        fileprivate var receipt: Receipt?
        fileprivate var inserted: ContinuousClock.Instant?
        fileprivate var rendererValidated = false
        fileprivate var frameClaimed = false

        fileprivate init(began: ContinuousClock.Instant) {
            self.began = began
        }
    }

    @MainActor final class Frame {
        let deadline: ContinuousClock.Instant
        private let check: @MainActor () -> Bool

        fileprivate init(deadline: ContinuousClock.Instant, check: @escaping @MainActor () -> Bool) {
            self.deadline = deadline
            self.check = check
        }

        func validate() -> Bool { check() }
    }

    private let isCurrentHost: @MainActor () -> Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private var active: Ticket?
    private var revision: UInt64 = 0

    init(
        isCurrentHost: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.isCurrentHost = isCurrentHost
        self.now = now
    }

    func begin() -> Ticket? {
        if let active { _ = isCurrent(active) }
        guard active == nil else { return nil }
        let revision = self.revision
        guard isCurrentHost(), active == nil, self.revision == revision else { return nil }
        let ticket = Ticket(began: now())
        active = ticket
        return ticket
    }

    func didInsert(_ ticket: Ticket, receipt: Receipt) -> Bool {
        guard isCurrent(ticket) else { return false }
        guard ticket.receipt == nil, !receipt.leaseID.isEmpty, receipt.leaseID.utf8.count <= 128,
              !receipt.render.isEmpty, receipt.render.utf8.count <= 1024 * 1024 else {
            invalidate()
            return false
        }
        ticket.receipt = receipt
        ticket.inserted = now()
        return true
    }

    func didValidate(_ ticket: Ticket, receipt: Receipt, rendererConfirmed: Bool) -> Bool {
        guard isCurrent(ticket) else { return false }
        guard rendererConfirmed, ticket.receipt == receipt, let inserted = ticket.inserted else {
            invalidate()
            return false
        }
        guard inserted.duration(to: now()) >= .milliseconds(150) else { return false }
        ticket.rendererValidated = true
        return true
    }

    func claimFrame(_ ticket: Ticket) -> Frame? {
        guard isCurrent(ticket), ticket.rendererValidated, !ticket.frameClaimed else { return nil }
        ticket.frameClaimed = true
        return Frame(deadline: ticket.began.advanced(by: .seconds(2))) { [weak self, weak ticket] in
            guard let self, let ticket else { return false }
            return self.isCurrent(ticket) && ticket.rendererValidated && ticket.frameClaimed
        }
    }

    func invalidate() {
        revision &+= 1
        active = nil
    }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        guard active === ticket else { return false }
        let hostIsCurrent = isCurrentHost()
        guard active === ticket else { return false }
        let current = now()
        guard ticket.began <= current, current < ticket.began.advanced(by: .seconds(2)), hostIsCurrent else {
            invalidate()
            return false
        }
        return true
    }
}
