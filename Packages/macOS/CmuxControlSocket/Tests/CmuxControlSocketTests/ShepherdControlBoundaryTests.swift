import Foundation
import Darwin
import Testing
@testable import CmuxControlSocket

@Suite(.serialized)
@MainActor
struct ShepherdControlBoundaryTests {
    private let boot = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let owner = ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
    private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func setup(hostInstance: UUID? = nil) -> (
        ShepherdControlBoundary, ShepherdAdmissionHostProbe, ShepherdAdmissionClockProbe, ScreenProbe
    ) {
        let host = ShepherdAdmissionHostProbe()
        host.current?.screenFingerprint = digest
        let clock = ShepherdAdmissionClockProbe()
        let screen = ScreenProbe()
        let boundary = ShepherdControlBoundary(
            host: host, hostInstance: hostInstance ?? boot, now: { clock.now },
            unixMilliseconds: { 1_792_345_678_901 },
            readVisibleScreen: { workspace, surface in
                screen.targets.append([workspace, surface])
                screen.action?()
                return screen.text
            },
            wait: { try await clock.wait($0) }
        )
        return (boundary, host, clock, screen)
    }

    private func inspect(_ host: ShepherdAdmissionHostProbe) throws -> ControlRequest {
        let snapshot = try #require(host.current)
        return ControlRequest(id: .int(7), method: "surface.shepherd.inspect", params: [
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "surface_id": .string(snapshot.surfaceID.uuidString)
        ])
    }

    private func payload(_ result: ControlCallResult) throws -> [String: JSONValue] {
        guard case .ok(.object(let value)) = result else {
            Issue.record("Expected a successful wire result, got \(result)")
            throw ProbeFailure.unexpectedResult
        }
        #expect(value["protocol_version"] == .int(1))
        #expect(value["host_instance"] == .string(boot.uuidString))
        return value
    }

    private func errorCode(_ result: ControlCallResult, expectedBoot: UUID? = nil) throws -> String {
        guard case .err(let code, _, .object(let value)) = result else {
            Issue.record("Expected an explicit wire error, got \(result)")
            throw ProbeFailure.unexpectedResult
        }
        #expect(value["protocol_version"] == .int(1))
        #expect(value["host_instance"] == .string((expectedBoot ?? boot).uuidString))
        return code
    }

    private func continuation(
        _ token: JSONValue?, requestID: UUID = UUID(), text: String = "Continue."
    ) throws -> ControlRequest {
        guard case .object(let value) = token, case .string(let id) = value["id"] else {
            throw ProbeFailure.unexpectedResult
        }
        return ControlRequest(id: .int(8), method: "surface.shepherd.continue", params: [
            "request_id": .string(requestID.uuidString), "token": .string(id), "text": .string(text)
        ])
    }

    // Removing same-user/local checks would expose terminal facts and tokens.
    @Test
    func refusesUnknownOtherUserAndRelayPeersBeforeReadingTheHost() async throws {
        let (boundary, host, _, screen) = setup()
        let request = try inspect(host)
        let peers: [ShepherdControlPeer?] = [
            nil,
            ShepherdControlPeer(peerHasSameUID: false, isRemoteRelay: false),
            ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: true)
        ]
        for peer in peers {
            #expect(try errorCode(await boundary.handle(request, peer: peer)) == "access_denied")
            #expect(try errorCode(boundary.handleSynchronously(request, peer: peer)) == "access_denied")
        }
        #expect(host.events.isEmpty && screen.targets.isEmpty)
    }

    @Test
    func authorizationPrecedesParameterDecodingForEveryNativeMethod() async throws {
        let (boundary, host, _, screen) = setup()
        for method in ShepherdControlRequest.Method.allCases {
            let malformed = ControlRequest(id: nil, method: method.rawValue, params: [:])
            #expect(try errorCode(await boundary.handle(malformed, peer: nil)) == "access_denied")
            #expect(try errorCode(await boundary.handle(malformed, peer: owner)) == "invalid_params")
        }
        let unknown = ControlRequest(id: nil, method: "surface.send_key", params: [:])
        #expect(try errorCode(await boundary.handle(unknown, peer: owner)) == "method_not_found")
        #expect(host.events.isEmpty && screen.targets.isEmpty)
    }

    @Test
    func inspectBindsExactCanonicalBytesAndSeparatesUptimeFromUnixMilliseconds() async throws {
        let (boundary, host, _, screen) = setup()
        let before = try #require(host.current)
        let value = try payload(await boundary.handle(inspect(host), peer: owner))
        #expect(value["screen"] == .string("abc"))
        #expect(value["observed_at_uptime_seconds"] == .double(100))
        #expect(value["observed_at_unix_ms"] == .int(1_792_345_678_901))
        let snapshot = try #require(value["snapshot"])
        guard case .object(let fields) = snapshot else { throw ProbeFailure.unexpectedResult }
        #expect(fields == [
            "workspace_id": .string(before.workspaceID.uuidString),
            "surface_id": .string(before.surfaceID.uuidString),
            "process_instance": .string("123:456"), "surface_generation": .int(1),
            "agent": .string("Copilot"), "cwd": .string("/synthetic/project"), "tty": .string("/dev/ttys007"),
            "screen_fingerprint": .string(digest),
            "outside_composer_fingerprint": .string("outside-before"),
            "input_revision": .int(10), "focus_revision": .int(20),
            "focused": .bool(false), "idle": .bool(true),
            "composer": .object(["state": .string("empty"), "draft_length": .int(0)]),
            "background_work": .bool(false), "accepts_immediate_input": .bool(true)
        ])
        guard case .object(let token) = value["token"] else { throw ProbeFailure.unexpectedResult }
        #expect(token["expires_at_uptime_seconds"] == .double(102))
        guard case .string(let id) = token["id"] else { throw ProbeFailure.unexpectedResult }
        #expect(UUID(uuidString: id) != nil)
        #expect(screen.targets == [[before.workspaceID, before.surfaceID]])
        #expect(host.events == ["read"] && host.pasteCalls == 0)
    }

    @Test(arguments: [nil, "", "abd", "abc\n", " abc"])
    func missingOrDifferentCanonicalScreenCannotExposeAnInputToken(text: String?) async throws {
        let (boundary, host, _, screen) = setup()
        screen.text = text
        let value = try payload(await boundary.handle(inspect(host), peer: owner))
        #expect(value["token"] == .null)
        #expect(value["screen"] == .null)
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
    }

    @Test
    func matchingScreenDoesNotTurnUnknownFactsIntoReadiness() async throws {
        let (boundary, host, _, _) = setup()
        host.current?.idle = nil
        host.current?.backgroundWork = nil
        host.current?.processInstance = nil
        host.current?.agent = nil
        host.current?.workingDirectory = nil
        host.current?.tty = nil
        host.current?.composer = .unknown
        let value = try payload(await boundary.handle(inspect(host), peer: owner))
        #expect(value["screen"] == .string("abc") && value["token"] == .null)
        guard case .object(let fields) = value["snapshot"] else { throw ProbeFailure.unexpectedResult }
        #expect(fields["idle"] == .null && fields["background_work"] == .null)
        #expect(fields["process_instance"] == .null)
        #expect(fields["agent"] == .null && fields["cwd"] == .null && fields["tty"] == .null)
        #expect(fields["composer"] == .object(["state": .string("unknown"), "draft_length": .null]))
    }

    @Test
    func wireComposerNeverIncludesTheLiteralDraft() async throws {
        let (boundary, host, _, _) = setup()
        host.current?.composer = .draft("private draft")
        let value = try payload(await boundary.handle(inspect(host), peer: owner))
        guard case .object(let fields) = value["snapshot"] else { throw ProbeFailure.unexpectedResult }
        #expect(fields["composer"] == .object(["state": .string("draft"), "draft_length": .int(13)]))
        #expect(value["token"] == .null)
    }

    @Test
    func missingTargetIsAnErrorWithoutAReplacementFocusedTarget() async throws {
        let (boundary, host, _, screen) = setup()
        let request = try inspect(host)
        host.current = nil
        #expect(try errorCode(await boundary.handle(request, peer: owner)) == "target_unavailable")
        #expect(screen.targets.isEmpty && host.pasteCalls == 0)
    }

    @Test
    func acceptedReceiptAndReplayKeepExactNativeIdentityAndAdmittedEffects() async throws {
        let (boundary, host, clock, _) = setup()
        let original = try #require(host.current)
        let observation = try payload(await boundary.handle(inspect(host), peer: owner))
        let id = UUID()
        let intent = try continuation(observation["token"], requestID: id)
        let accepted = try payload(await boundary.handle(intent, peer: owner))
        #expect(accepted == [
            "protocol_version": .int(1), "host_instance": .string(boot.uuidString),
            "request_id": .string(id.uuidString),
            "workspace_id": .string(original.workspaceID.uuidString),
            "surface_id": .string(original.surfaceID.uuidString),
            "process_instance": .string("123:456"), "state": .string("accepted"),
            "reason": .string("paste_and_submit_admitted"), "paste_admitted": .bool(true),
            "submit_admitted": .bool(true)
        ])
        host.current = nil
        let lookup = ControlRequest(id: .int(9), method: "surface.shepherd.receipt", params: [
            "request_id": .string(id.uuidString)
        ])
        #expect(try payload(await boundary.handle(lookup, peer: owner)) == accepted)
        #expect(try payload(await boundary.handle(intent, peer: owner)) == accepted)
        #expect(host.pasteCalls == 1 && host.submitCalls == 1 && clock.waits == [0.15])
    }

    @Test
    func unknownReceiptIsNotFoundNeverEvidenceOfZeroInput() async throws {
        let (boundary, host, _, _) = setup()
        let lookup = ControlRequest(id: nil, method: "surface.shepherd.receipt", params: [
            "request_id": .string(UUID().uuidString)
        ])
        #expect(try errorCode(await boundary.handle(lookup, peer: owner)) == "not_found")
        #expect(host.events.isEmpty)
    }

    @Test
    func synchronousContinuationRefusesWithoutConsumingItsToken() async throws {
        let (boundary, host, _, _) = setup()
        let observation = try payload(boundary.handleSynchronously(inspect(host), peer: owner))
        let intent = try continuation(observation["token"])
        #expect(try errorCode(boundary.handleSynchronously(intent, peer: owner)) == "async_required")
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
        #expect(try payload(await boundary.handle(intent, peer: owner))["state"] == .string("accepted"))
    }

    @Test
    func cancelledConnectionTaskRetainsPartialPasteAndWithholdsSubmit() async throws {
        let (boundary, host, clock, _) = setup()
        let observation = try payload(await boundary.handle(inspect(host), peer: owner))
        let id = UUID()
        let intent = try continuation(observation["token"], requestID: id)
        clock.action = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let operation = Task { await boundary.handle(intent, peer: owner) }
        let result = try payload(await operation.value)
        #expect(result["state"] == .string("unknown"))
        #expect(result["reason"] == .string("request_cancelled"))
        #expect(result["paste_admitted"] == .bool(true) && result["submit_admitted"] == .bool(false))
        #expect(try payload(await boundary.handle(intent, peer: owner)) == result)
        #expect(host.pasteCalls == 1 && host.submitCalls == 0 && host.released == [id])
    }

    @Test
    func preCancelledOperationAndUnknownTokenAreExplicitNonReceiptErrors() async throws {
        let (boundary, host, _, _) = setup()
        let observation = try payload(await boundary.handle(inspect(host), peer: owner))
        let intent = try continuation(observation["token"])
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await boundary.handle(intent, peer: owner)
        }
        #expect(try errorCode(await operation.value) == "cancelled")
        let unknown = ControlRequest(id: nil, method: "surface.shepherd.continue", params: [
            "request_id": .string(UUID().uuidString), "token": .string(UUID().uuidString),
            "text": .string("Continue.")
        ])
        #expect(try errorCode(await boundary.handle(unknown, peer: owner)) == "unknown_token")
        #expect(host.pasteCalls == 0 && host.submitCalls == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1])
    func invalidUptimeFailsExplicitlyRatherThanProducingInvalidJSON(now: Double) async throws {
        let (boundary, host, clock, screen) = setup()
        clock.now = now
        #expect(try errorCode(await boundary.handle(inspect(host), peer: owner)) == "clock_unavailable")
        #expect(host.events.isEmpty && screen.targets.isEmpty)
    }

    @Test
    func slowCanonicalCaptureCannotExposeAnAlreadyExpiredToken() async throws {
        let (boundary, host, clock, screen) = setup()
        screen.action = { clock.now += 3 }
        let value = try payload(await boundary.handle(inspect(host), peer: owner))
        #expect(value["screen"] == .string("abc") && value["token"] == .null)
        #expect(value["observed_at_uptime_seconds"] == .double(100))
    }

    @Test
    func restartedBoundaryCannotReplayAnotherBootsTokenOrClaimItsMissingReceiptIsNotSent() async throws {
        let (first, host, _, _) = setup()
        let observation = try payload(await first.handle(inspect(host), peer: owner))
        let intent = try continuation(observation["token"])
        let nextBoot = UUID()
        let (second, nextHost, _, _) = setup(hostInstance: nextBoot)
        #expect(try errorCode(await second.handle(intent, peer: owner), expectedBoot: nextBoot) == "unknown_token")
        let lookup = ControlRequest(id: nil, method: "surface.shepherd.receipt", params: [
            "request_id": try #require(intent.params["request_id"])
        ])
        #expect(try errorCode(await second.handle(lookup, peer: owner), expectedBoot: nextBoot) == "not_found")
        #expect(nextHost.events.isEmpty && nextHost.pasteCalls == 0)
    }

    @Test(arguments: [false, true])
    func realConnectionTerminationAfterPasteRetainsUnknownReceiptWithoutSubmitting(revoked: Bool) async throws {
        let (boundary, host, clock, _) = setup()
        let observation = try payload(await boundary.handle(inspect(host), peer: owner))
        let id = UUID()
        let intent = try continuation(observation["token"], requestID: id)
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        let signal = SocketAuthorizationRevocationSignal()
        let reader = ControlClientAsyncLineReader(
            socket: pair.reader, authorizationRevocationSignal: signal
        )
        let pasted = AsyncStream<Void>.makeStream()
        clock.action = { _ in
            pasted.continuation.yield(())
            pasted.continuation.finish()
            try await Task.sleep(for: .seconds(5))
        }
        let peer = owner
        let operation = Task {
            await reader.performWhileConnected { await boundary.handle(intent, peer: peer) }
        }
        for await _ in pasted.stream { break }
        #expect(host.pasteCalls == 1 && host.submitCalls == 0)
        if revoked {
            signal.revoke()
        } else {
            #expect(shutdown(pair.writer, SHUT_WR) == 0)
        }
        let outcome = await operation.value
        let value = try payload(outcome)
        #expect(value["request_id"] == .string(id.uuidString))
        #expect(value["state"] == .string("unknown") && value["reason"] == .string("request_cancelled"))
        #expect(value["paste_admitted"] == .bool(true) && value["submit_admitted"] == .bool(false))
        let lookup = ControlRequest(id: .int(11), method: "surface.shepherd.receipt", params: [
            "request_id": .string(id.uuidString)
        ])
        #expect(try payload(await boundary.handle(lookup, peer: owner)) == value)
        #expect(host.pasteCalls == 1 && host.submitCalls == 0 && host.released == [id])
        let wire = ControlResponseEncoder().response(id: lookup.id, outcome)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any]
        )
        #expect(envelope["id"] as? Int == 11 && envelope["ok"] as? Bool == true)
        #expect((envelope["result"] as? [String: Any])?["state"] as? String == "unknown")
        await reader.cancelAndWait()
    }

    private enum ProbeFailure: Error { case unexpectedResult }

    @MainActor
    private final class ScreenProbe {
        var text: String? = "abc"
        var targets: [[UUID]] = []
        var action: (@MainActor () -> Void)?
    }
}
