internal import Darwin
import Foundation

@main
struct ManagedRendererControllerFixture {
    enum Failure: Error { case assertion(String), bridge }
    typealias Controller = AgentSessionManagedRendererController

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
        let owner = NSObject()
        let host = NSObject()
        let began = ContinuousClock.now
        var now = began
        var context: Controller.Context? = .init(
            owner: ObjectIdentifier(owner), store: ObjectIdentifier(host),
            coordinator: ObjectIdentifier(host), host: ObjectIdentifier(host),
            webView: ObjectIdentifier(host), window: ObjectIdentifier(host), responder: ObjectIdentifier(host),
            workspaceID: UUID(), panelID: UUID(), renderer: "react", document: "file:///controlled/index.html",
            paintGeneration: 1, geometry: [0, 0, 800, 600]
        )
        let originalContext = context
        var captureReply: Any? = ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                                 "screen": "Visible output\n  exact spacing \n"]
        var receiptReply: Any? = ["leaseId": "lease-1", "render": "paint-2"]
        var validationReply: Any? = true
        var hook: ((Controller.Operation) throws -> Void)?
        var released: [String] = []
        var releaseErrors = 0
        var reservedText: String?
        var validations = 0
        var contextHook: (() -> Void)?
        let bridge: (Controller.Operation) async throws -> Any? = { operation in
            try hook?(operation)
            switch operation {
            case .capture: return captureReply
            case .reserve(let snapshot, let text):
                try check(snapshot == ["editorText": scenario == "draft-whitespace" ? " \n\t"
                                        : scenario == "draft-refused" ? "human draft" : "",
                                       "editVersion": "edit-1", "render": "paint-1",
                                       "screen": "Visible output\n  exact spacing \n"],
                          "controller changed captured renderer evidence")
                reservedText = text
                return receiptReply
            case .validate(let receipt):
                validations += 1
                try check(receipt == ["leaseId": "lease-1", "render": "paint-2"], "wrong validation receipt")
                return validationReply
            case .release(let leaseID):
                released.append(leaseID)
                return nil
            }
        }
        let controller = Controller(
            context: { contextHook?(); return context }, operation: bridge, now: { now },
            sleep: { duration in
                if scenario == "cancelled-separation" { throw CancellationError() }
                now = now.advanced(by: duration)
            },
            onReleaseError: { _ in releaseErrors += 1 }
        )
        if scenario == "capture-reentry" {
            hook = { if case .capture = $0 { controller.invalidate() } }
            let snapshot = try await controller.capture()
            try check(snapshot == nil, "late capture survived native invalidation")
            return
        }
        if scenario == "capture-late-reply" {
            hook = { if case .capture = $0 { now = began.advanced(by: .seconds(2)) } }
            let snapshot = try await controller.capture()
            try check(snapshot == nil, "expired capture reply minted a fresh observation")
            return
        }
        if scenario == "strict-dictionaries" {
            let badSnapshots: [Any] = [
                ["editorText": "", "editVersion": "edit-1", "render": "paint-1", "screen": "visible",
                 "extra": "unbound"],
                ["editorText": 1, "editVersion": "edit-1", "render": "paint-1", "screen": "visible"],
                ["editorText": "", "editVersion": "", "render": "paint-1", "screen": "visible"],
                ["editorText": "", "editVersion": "edit-1", "render": "", "screen": "visible"],
                ["editorText": "", "editVersion": "edit-1", "render": String(repeating: "x", count: 1_048_577),
                 "screen": "visible"],
                ["editorText": "", "editVersion": "edit-1", "render": "paint-1"],
                ["editorText": "", "editVersion": "edit-1", "render": "paint-1", "screen": 1],
                ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                 "screen": String(repeating: "x", count: 1_048_577)],
            ]
            for bad in badSnapshots {
                captureReply = bad
                let snapshot = try await controller.capture()
                try check(snapshot == nil, "malformed snapshot admitted")
            }
            captureReply = ["editorText": "", "editVersion": "edit-1", "render": "paint-1", "screen": ""]
            let emptyScreen = try await controller.capture()
            try check(emptyScreen?.screen == "", "native snapshot refused an exact empty visible screen")
            captureReply = ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                            "screen": "Visible output\n  exact spacing \n"]
            let badReceipts: [Any] = [
                ["leaseId": "", "render": "paint-2"],
                ["leaseId": "lease-1", "render": "paint-2", "extra": "unbound"],
                ["leaseId": 1, "render": "paint-2"],
            ]
            for bad in badReceipts {
                guard let snapshot = try await controller.capture() else { throw Failure.assertion("missing capture") }
                try check(snapshot.screen == "Visible output\n  exact spacing \n",
                          "native snapshot normalized or substituted visible plaintext")
                receiptReply = bad
                let insertion = try await controller.insert(snapshot, text: "literal")
                try check(insertion == nil, "malformed receipt admitted")
            }
            return
        }
        if scenario.hasPrefix("draft-") {
            captureReply = ["editorText": scenario == "draft-whitespace" ? " \n\t" : "human draft",
                            "editVersion": "edit-1", "render": "paint-1",
                            "screen": "Visible output\n  exact spacing \n"]
        }
        guard let snapshot = try await controller.capture() else { throw Failure.assertion("missing capture") }
        if scenario == "capture-expired" {
            now = began.advanced(by: .seconds(2))
            let insertion = try await controller.insert(snapshot, text: "expired observation")
            try check(insertion == nil && reservedText == nil,
                      "expired observation invoked the editor with a renewed insertion budget")
            return
        }
        if scenario == "capture-delayed-insertion" {
            now = began.advanced(by: .milliseconds(1800))
            hook = { if case .reserve = $0 { now = now.advanced(by: .milliseconds(100)) } }
            guard let insertion = try await controller.insert(snapshot, text: "literal") else {
                throw Failure.assertion("missing in-budget insertion")
            }
            let frame = try await controller.prepareFrame(insertion)
            try check(frame == nil, "processing separation renewed an expired observation budget")
            return
        }
        if scenario == "capture-clipped-frame" {
            now = began.advanced(by: .milliseconds(1600))
            guard let insertion = try await controller.insert(snapshot, text: "literal"),
                  let submission = try await controller.prepareSubmission(insertion, inputID: UUID()) else {
                throw Failure.assertion("missing in-budget submission")
            }
            try check(submission.deadline == began.advanced(by: .seconds(2)),
                      "submission deadline was renewed at insertion")
            try check(submission.claim(owner: owner, store: host), "fresh narrowed submission refused")
            now = began.advanced(by: .seconds(2))
            try check(!submission.validate(owner: owner, store: host),
                      "narrowed submission frame survived the original observation deadline")
            return
        }
        if scenario.hasPrefix("draft-") {
            let insertion = try await controller.insert(snapshot, text: "automatic literal")
            try check(insertion == nil && reservedText == nil, "native automatic insertion replaced a human draft")
            return
        }
        if scenario == "snapshot-custody" {
            let foreign = Controller(
                context: { context }, operation: bridge, now: { now },
                sleep: { _ in }, onReleaseError: { _ in }
            )
            let cross = try await foreign.insert(snapshot, text: "foreign")
            try check(cross == nil && reservedText == nil, "foreign controller used snapshot")
            context = nil
            let lost = try await controller.insert(snapshot, text: "lost")
            try check(lost == nil && reservedText == nil, "lost context inserted")
            context = originalContext
            let restored = try await controller.insert(snapshot, text: "ABA")
            try check(restored == nil && reservedText == nil, "context loss revived stale snapshot")
            return
        }
        if scenario == "insert-reentry" {
            hook = { if case .reserve = $0 { controller.invalidate() } }
            let insertion = try await controller.insert(snapshot, text: "literal\n<script>")
            try check(insertion == nil, "late insertion admitted")
            for _ in 0..<20 { await Task.yield() }
            try check(released == ["lease-1"], "late insertion lease not released")
            return
        }
        if scenario == "bridge-error" {
            hook = { if case .reserve = $0 { throw Failure.bridge } }
            do {
                _ = try await controller.insert(snapshot, text: "literal")
                throw Failure.assertion("bridge error swallowed")
            } catch Failure.bridge {}
            hook = nil
            let stale = try await controller.insert(snapshot, text: "stale")
            try check(stale == nil, "bridge error did not revoke snapshot")
            return
        }
        if scenario == "delayed-insertion" {
            hook = { if case .reserve = $0 { now = began.advanced(by: .milliseconds(600)) } }
        }
        guard let insertion = try await controller.insert(snapshot, text: "literal\n<script>") else {
            throw Failure.assertion("missing insertion")
        }
        try check(reservedText == "literal\n<script>", "text was not passed literally")
        if scenario.hasPrefix("submission-") {
            let inputID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            if scenario == "submission-custody" {
                let other = Controller(
                    context: { context }, operation: bridge, now: { now },
                    sleep: { _ in }, onReleaseError: { _ in }
                )
                let foreign = try await other.prepareSubmission(insertion, inputID: inputID)
                try check(foreign == nil, "foreign controller rebound an insertion")
            }
            guard let submission = try await controller.prepareSubmission(insertion, inputID: inputID) else {
                throw Failure.assertion("missing bound submission")
            }
            try check(submission.inputID == inputID && submission.text == "literal\n<script>",
                      "submission lost its exact native UUID or inserted literal")
            let repeated = try await controller.prepareSubmission(insertion, inputID: UUID())
            try check(repeated == nil, "one insertion minted a second input binding")
            let foreignOwner = NSObject()
            let foreignStore = NSObject()
            if scenario == "submission-claim-reentry" {
                var innerClaim: Bool?
                contextHook = {
                    contextHook = nil
                    innerClaim = submission.claim(owner: owner, store: host)
                }
                let outerClaim = submission.claim(owner: owner, store: host)
                try check(innerClaim == true && !outerClaim, "reentrant validation claimed the same input twice")
                return
            }
            try check(!submission.claim(owner: foreignOwner, store: host), "foreign owner claimed renderer evidence")
            try check(!submission.claim(owner: owner, store: foreignStore), "foreign store claimed renderer evidence")
            try check(!submission.validate(owner: owner, store: host), "unclaimed input evidence was usable")
            try check(submission.claim(owner: owner, store: host), "exact native owner/store could not claim evidence")
            try check(!submission.claim(owner: owner, store: host), "submission input binding was reusable")
            if scenario == "submission-revoked" { context = nil }
            if scenario == "submission-expired" { now = began.advanced(by: .seconds(2)) }
            let pipe = Pipe()
            let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
            defer {
                try? writer.close()
                try? pipe.fileHandleForReading.close()
            }
            let bytes = Data(submission.text.utf8)
            let result = await writer.write(bytes, deadline: submission.deadline) {
                submission.validate(
                    owner: scenario == "submission-foreign-owner" ? foreignOwner : owner,
                    store: scenario == "submission-foreign-store" ? foreignStore : host
                )
            }
            if ["submission-revoked", "submission-expired", "submission-foreign-owner", "submission-foreign-store"]
                .contains(scenario) {
                try check(result == .notWritten(.guardInvalidated), "stale bound submission admitted a byte")
                let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL, 0)
                try check(flags >= 0 && fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                          "could not inspect actual pipe admission")
                var byte: UInt8 = 0
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &byte, 1)
                try check(count == -1 && errno == EAGAIN, "refused bound submission left bytes in the actual pipe")
            } else {
                try check(result == .complete(bytes.count), "bound writer refused current exact literal: \(result)")
                let actual = try pipe.fileHandleForReading.read(upToCount: bytes.count)
                try check(actual == Data("literal\n<script>".utf8), "actual pipe literal differs from editor insertion")
            }
            return
        }
        if scenario == "finish-custody" || scenario == "release-error" {
            if scenario == "release-error" {
                hook = { if case .release = $0 { throw Failure.bridge } }
            }
            controller.finish(insertion)
            for _ in 0..<20 { await Task.yield() }
            if scenario == "release-error" {
                try check(releaseErrors == 1, "release error was silently discarded")
                return
            }
            try check(released == ["lease-1"], "finish did not release the exact lease")
            guard let fresh = try await controller.capture(),
                  let next = try await controller.insert(fresh, text: "new") else {
                throw Failure.assertion("finish left native reservation occupied")
            }
            controller.finish(insertion)
            let nextFrame = try await controller.prepareFrame(next)
            try check(nextFrame != nil, "old finish revoked a fresh reservation")
            return
        }
        if scenario == "expired-recovery" {
            now = began.advanced(by: .seconds(2))
            let fresh = try await controller.capture()
            try check(fresh != nil, "expired insertion permanently occupied the controller")
            let staleFrame = try await controller.prepareFrame(insertion)
            try check(staleFrame == nil, "expired reservation minted frame")
            for _ in 0..<20 { await Task.yield() }
            try check(released == ["lease-1"], "expired lease not released")
            return
        }
        if scenario == "cancelled-separation" {
            do {
                _ = try await controller.prepareFrame(insertion)
                throw Failure.assertion("sleep cancellation swallowed")
            } catch is CancellationError {}
            try check(validations == 0, "cancelled separation reached renderer validation")
            let fresh = try await controller.capture()
            try check(fresh != nil, "cancelled separation retained reservation")
            return
        }
        if scenario == "strict-boolean" { validationReply = NSNumber(value: 1) }
        if scenario == "validate-reentry" {
            hook = { if case .validate = $0 { controller.invalidate() } }
        }
        if scenario == "validate-expiry" {
            hook = { if case .validate = $0 { now = began.advanced(by: .seconds(2)) } }
        }
        let frame = try await controller.prepareFrame(insertion)
        if ["strict-boolean", "validate-reentry", "validate-expiry"].contains(scenario) {
            try check(frame == nil, "invalid renderer validation minted a frame")
            return
        }
        guard let frame else { throw Failure.assertion("missing frame") }
        try check(began.duration(to: now) >= .milliseconds(150), "native separation skipped")
        if scenario == "delayed-insertion" {
            try check(began.duration(to: now) >= .milliseconds(750), "reply delay bypassed native separation")
        }
        let second = try await controller.prepareFrame(insertion)
        try check(second == nil, "same insertion claimed two frames")
        let pipe = Pipe()
        let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
        defer {
            try? writer.close()
            try? pipe.fileHandleForReading.close()
        }
        if scenario == "writer-revocation" { context = nil }
        if scenario == "writer-backpressure" {
            let bytes = Data(repeating: 65, count: 256 * 1024)
            let pending = Task { await writer.write(bytes, deadline: frame.deadline, validate: frame.validate) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !writer.isAwaitingWritable {
                try check(ContinuousClock.now < deadline, "pipe did not reach backpressure")
                await Task.yield()
            }
            controller.invalidate()
            let result = await pending.value
            guard case .partial(let count, .guardInvalidated) = result else {
                throw Failure.assertion("event did not stop next syscall: \(result)")
            }
            try check(count > 0 && count < bytes.count && writer.streamIsTainted, "partial uncertainty lost")
        } else {
            let result = await writer.write(Data("literal".utf8), deadline: frame.deadline, validate: frame.validate)
            if scenario == "writer-revocation" {
                try check(result == .notWritten(.guardInvalidated), "lost context admitted first pipe byte")
            } else {
                try check(result == .complete(7), "guarded writer failed: \(result)")
                let bytes = try pipe.fileHandleForReading.read(upToCount: 7)
                try check(bytes == Data("literal".utf8), "wrong actual pipe bytes")
            }
        }
        try check(releaseErrors == 0, "unexpected release error")
    }
}
