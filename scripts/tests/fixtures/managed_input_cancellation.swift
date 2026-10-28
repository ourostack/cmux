internal import Darwin
import Foundation

@main
struct ManagedInputCancellationFixture {
    enum Failure: Error { case assertion(String) }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func main() async {
        do {
            guard let scenario = CommandLine.arguments.dropFirst().first else {
                throw Failure.assertion("missing scenario")
            }
            let owner = NSObject()
            let identity = ObjectIdentifier(owner)
            let context = AgentSessionManagedRendererController.Context(
                owner: identity, store: identity, coordinator: identity, host: identity, webView: identity,
                window: identity, responder: identity, workspaceID: UUID(), panelID: UUID(), renderer: "react",
                document: "file:///controlled/cancellation-host.html", paintGeneration: 1, geometry: [0, 0, 800, 600]
            )
            let cancellation = AgentSessionManagedInputCancellation()
            var now = ContinuousClock.now
            var cancelDuringContext = false
            let controller = AgentSessionManagedRendererController(
                context: {
                    if cancelDuringContext { cancellation.cancel() }
                    return context
                },
                operation: { operation in
                    switch operation {
                    case .capture:
                        return ["editorText": "", "editVersion": "edit-1", "render": "paint-1",
                                "screen": "Visible output"]
                    case .reserve: return ["leaseId": "lease-1", "render": "paint-2"]
                    case .validate: return true
                    case .release: return nil
                    case .consume: return true
                    }
                }, now: { now }, sleep: { now = now.advanced(by: $0) },
                onReleaseError: { error in fatalError("unexpected controlled release failure: \(error)") }
            )
            guard let snapshot = try await controller.capture(),
                  let insertion = try await controller.insert(snapshot, text: "Owned literal"),
                  let submission = try await controller.prepareSubmission(
                    insertion, inputID: UUID(), cancellation: cancellation
                  ) else { throw Failure.assertion("missing live submission") }
            if scenario == "before-claim" {
                await Task.detached { cancellation.cancel() }.value
                try check(cancellation.isCancelled && !submission.claim(owner: owner, store: owner),
                          "cancelled native request claimed a submission")
                print("passed")
                return
            }
            if scenario == "during-claim" {
                cancelDuringContext = true
                try check(!submission.claim(owner: owner, store: owner),
                          "cancellation during the native predicate claimed the same submission")
                print("passed")
                return
            }
            try check(submission.claim(owner: owner, store: owner), "live submission could not be claimed")
            let pipe = Pipe()
            let writer = try ShepherdManagedPipeWriter(takingOwnershipOf: pipe.fileHandleForWriting)
            defer {
                try? writer.close()
                try? pipe.fileHandleForReading.close()
            }
            if scenario == "before-byte" {
                await Task.detached { cancellation.cancel() }.value
                let result = await writer.write(
                    Data("must not write".utf8), deadline: submission.deadline,
                    validate: { submission.validate(owner: owner, store: owner) }
                )
                try check(result == .notWritten(.guardInvalidated),
                          "request cancellation admitted the independent writer's first byte")
            } else if scenario == "backpressure" {
                let bytes = Data(repeating: 65, count: 256 * 1024)
                let write = Task {
                    await writer.write(bytes, deadline: submission.deadline) {
                        submission.validate(owner: owner, store: owner)
                    }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !writer.isAwaitingWritable {
                    try check(ContinuousClock.now < deadline, "controlled writer did not reach backpressure")
                    await Task.yield()
                }
                let request = Task {
                    await withTaskCancellationHandler {
                        while !Task.isCancelled { await Task.yield() }
                    } onCancel: {
                        cancellation.cancel()
                    }
                }
                request.cancel()
                await request.value
                let result = await write.value
                guard case .partial(let count, .guardInvalidated) = result else {
                    throw Failure.assertion("request cancellation did not stop partial writer: \(result)")
                }
                try check(count > 0 && count < bytes.count && writer.streamIsTainted,
                          "partial request cancellation lost byte uncertainty")
            } else {
                throw Failure.assertion("unknown scenario")
            }
            print("passed")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
