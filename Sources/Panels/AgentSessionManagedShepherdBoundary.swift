import CmuxControlSocket
import CryptoKit
import Foundation

@MainActor
final class AgentSessionManagedShepherdBoundary {
    enum Method: String, CaseIterable, Sendable {
        case inspect = "surface.shepherd.managed.inspect"
        case continueInput = "surface.shepherd.managed.continue"
        case receipt = "surface.shepherd.managed.receipt"
    }

    struct Target {
        let nativeOwner: AgentSessionManagedNativeOwner
        let store: AgentSessionProcessStore
        let renderer: AgentSessionManagedRendererController
        let sessionID: String
    }

    private final class Observation {
        weak var owner: AgentSessionManagedNativeOwner?
        weak var store: AgentSessionProcessStore?
        weak var renderer: AgentSessionManagedRendererController?
        let sessionID: String
        let snapshot: AgentSessionManagedRendererController.Snapshot
        let state: ShepherdManagedSessionState
        let deadline: ContinuousClock.Instant

        init(target: Target, snapshot: AgentSessionManagedRendererController.Snapshot,
             state: ShepherdManagedSessionState, deadline: ContinuousClock.Instant) {
            owner = target.nativeOwner
            store = target.store
            renderer = target.renderer
            sessionID = target.sessionID
            self.snapshot = snapshot
            self.state = state
            self.deadline = min(deadline, snapshot.deadline)
        }
    }

    private final class Record {
        let requestID: UUID
        let tokenID: UUID
        let text: String
        let identity: ShepherdManagedSessionIdentity
        let cancellation: AgentSessionManagedInputCancellation
        var editorAttempted = false
        var editorInserted = false
        var backendWriteAdmitted = false
        var providerInputID: String?
        var failureReason: String?
        var reason = "registered"
        weak var renderer: AgentSessionManagedRendererController?
        var insertion: AgentSessionManagedRendererController.Insertion?
        var cleanupAttempted = false

        var accepted: Bool { editorInserted && backendWriteAdmitted && providerInputID != nil }

        init(requestID: UUID, tokenID: UUID, text: String, identity: ShepherdManagedSessionIdentity,
             cancellation: AgentSessionManagedInputCancellation) {
            self.requestID = requestID
            self.tokenID = tokenID
            self.text = text
            self.identity = identity
            self.cancellation = cancellation
        }
    }

    private let resolve: (UUID, UUID) -> Target?
    private var observations: [UUID: Observation] = [:]
    private var records: [UUID: Record] = [:]

    init(resolve: @escaping (UUID, UUID) -> Target?) {
        self.resolve = resolve
    }

    nonisolated func handle(_ request: ControlRequest, peer: ShepherdControlPeer?) async -> ControlCallResult {
        guard Method(rawValue: request.method) != nil else {
            return .err(code: "method_not_found", message: "Not a managed Shepherd method.", data: nil)
        }
        guard let peer, peer.peerHasSameUID, !peer.isRemoteRelay,
              request.params["_cmux_remote_workspace_id"] == nil else {
            return .err(code: "access_denied", message: "Managed Shepherd requires a same-user local peer.", data: nil)
        }
        let cancellation = AgentSessionManagedInputCancellation()
        return await withTaskCancellationHandler {
            await execute(request, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(
        _ request: ControlRequest, cancellation: AgentSessionManagedInputCancellation
    ) async -> ControlCallResult {
        guard let method = Method(rawValue: request.method) else { return failure("method_not_found") }
        let params = request.params
        switch method {
        case .inspect:
            guard Set(params.keys) == ["workspace_id", "surface_id"],
                  let workspace = uuid(params["workspace_id"]), let surface = uuid(params["surface_id"]) else {
                return failure("invalid_params")
            }
            guard !cancellation.isCancelled else { return failure("cancelled") }
            return await inspect(workspace: workspace, surface: surface, cancellation: cancellation)
        case .receipt:
            guard Set(params.keys) == ["request_id"], let id = uuid(params["request_id"]) else {
                return failure("invalid_params")
            }
            guard let record = records[id] else { return failure("not_found") }
            return receipt(record)
        case .continueInput:
            guard Set(params.keys) == ["request_id", "token", "text"],
                  let id = uuid(params["request_id"]), let token = uuid(params["token"]),
                  case .string(let text)? = params["text"], Self.validText(text) else {
                return failure("invalid_params")
            }
            return await continueInput(id: id, token: token, text: text, cancellation: cancellation)
        }
    }

    private func inspect(
        workspace: UUID, surface: UUID, cancellation: AgentSessionManagedInputCancellation
    ) async -> ControlCallResult {
        let began = ContinuousClock.now
        let uptime = ProcessInfo.processInfo.systemUptime
        let unix = Int64(Date().timeIntervalSince1970 * 1_000)
        observations = observations.filter { began < $0.value.deadline }
        guard let target = resolve(workspace, surface), let before = state(target),
              before.identity.workspaceID == workspace, before.identity.surfaceID == surface else {
            return failure("target_unavailable")
        }
        do {
            guard let snapshot = try await target.renderer.capture(), !cancellation.isCancelled,
                  let current = resolve(workspace, surface), sameTarget(target, current),
                  let after = state(current), sameState(before, after) else {
                return failure("target_unavailable")
            }
            let observation = Observation(
                target: target, snapshot: snapshot, state: after, deadline: began.advanced(by: .seconds(2))
            )
            let ready = after.hasCompleteWorkEvidence && snapshot.editorText.isEmpty &&
                ContinuousClock.now < observation.deadline
            var token: JSONValue = .null
            if ready, observations.count < 128 {
                let id = UUID()
                observations[id] = observation
                let duration = began.duration(to: observation.deadline).components
                token = .object([
                    "id": .string(id.uuidString),
                    "expires_at_uptime_seconds": .double(
                        uptime + Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    ),
                ])
            }
            return .ok(.object([
                "protocol_version": .int(1), "host_instance": .string(after.identity.hostInstance.uuidString),
                "identity": .object(encode(after.identity)),
                "cwd": .string(current.nativeOwner.workingDirectory),
                "screen": .string(snapshot.screen), "screen_fingerprint": .string(digest(snapshot.screen)),
                "render_fingerprint": .string(digest(snapshot.renderEvidence)),
                "event_revision": .string(after.eventRevision.uuidString),
                "activity_revision": .string(after.activityRevision.uuidString),
                "idle": .bool(after.hasCompleteWorkEvidence), "focused": .bool(false),
                "composer_empty": .bool(snapshot.editorText.isEmpty),
                "observed_at_uptime_seconds": .double(uptime), "observed_at_unix_ms": .int(unix),
                "token": token,
            ]))
        } catch {
            NSLog("agentSession.managedShepherd.capture.failed: %@", String(describing: error))
            return failure("observation_unavailable")
        }
    }

    private func continueInput(
        id: UUID, token: UUID, text: String, cancellation: AgentSessionManagedInputCancellation
    ) async -> ControlCallResult {
        if let prior = records[id] {
            guard prior.tokenID == token, prior.text.utf8.elementsEqual(text.utf8) else {
                return failure("request_conflict")
            }
            return receipt(prior)
        }
        guard let observation = observations[token] else { return failure("unknown_token") }
        guard records.count < 1_024 else { return failure("receipt_capacity") }
        let record = Record(
            requestID: id, tokenID: token, text: text, identity: observation.state.identity,
            cancellation: cancellation
        )
        records[id] = record
        observations.removeValue(forKey: token)
        guard !cancellation.isCancelled, ContinuousClock.now < observation.deadline,
              let target = currentTarget(observation) else {
            record.reason = "observation_invalidated"
            return receipt(record)
        }
        record.editorAttempted = true
        record.reason = "editor_insertion_unproven"
        do {
            guard let insertion = try await target.renderer.insert(observation.snapshot, text: text) else {
                return receipt(record)
            }
            record.editorInserted = true
            record.renderer = target.renderer
            record.insertion = insertion
            defer { target.renderer.finish(insertion) }
            guard !cancellation.isCancelled, ContinuousClock.now < observation.deadline,
                  currentTarget(observation) != nil,
                  let submission = try await target.renderer.prepareSubmission(
                    insertion, inputID: id, cancellation: cancellation, expiresAt: observation.deadline
                  ), !cancellation.isCancelled, ContinuousClock.now < observation.deadline,
                  currentTarget(observation) != nil else {
                record.reason = "native_submission_unavailable"
                record.insertion = nil
                return receipt(record)
            }
            record.reason = "backend_admission_unproven"
            let registered = target.store.beginManagedSupervisorInput(
                sessionId: target.sessionID, submission: submission, nativeOwner: target.nativeOwner,
                progress: { [weak self] progress in self?.update(id, progress: progress) }
            )
            guard registered else {
                record.insertion = nil
                return receipt(record)
            }
            while !record.accepted, record.failureReason == nil, !cancellation.isCancelled,
                  ContinuousClock.now < observation.deadline {
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch is CancellationError {
                    cancellation.cancel()
                    record.reason = "request_cancelled"
                    break
                }
                catch {
                    cancellation.cancel()
                    record.reason = "receipt_wait_failed"
                    NSLog("agentSession.managedShepherd.wait.failed: %@", String(describing: error))
                    break
                }
            }
            return receipt(record)
        } catch {
            record.insertion = nil
            record.reason = "editor_effect_unproven"
            NSLog("agentSession.managedShepherd.input.failed: %@", String(describing: error))
            return receipt(record)
        }
    }

    private func update(_ id: UUID, progress: AgentSessionManagedInputProgress) {
        guard let record = records[id] else { return }
        guard progress.matches(
            inputID: id, identity: record.identity, backendWriteAdmitted: record.backendWriteAdmitted,
            providerInputID: record.providerInputID
        ) else {
            record.cancellation.cancel()
            record.reason = "progress_identity_mismatch"
            return
        }
        record.backendWriteAdmitted = progress.backendWriteAdmitted
        record.providerInputID = progress.providerInputID
        record.failureReason = progress.failureReason
        if progress.failureReason != nil { record.insertion = nil }
        record.reason = record.accepted ? "provider_acknowledged"
            : progress.failureReason ?? (progress.backendWriteAdmitted ? "provider_ack_pending" : "backend_admission_pending")
        guard record.accepted, !record.cleanupAttempted,
              let renderer = record.renderer, let insertion = record.insertion else { return }
        record.cleanupAttempted = true
        record.insertion = nil
        Task { @MainActor in
            do { _ = try await renderer.consume(insertion) }
            catch { NSLog("agentSession.managedShepherd.consume.failed: %@", String(describing: error)) }
        }
    }

    private func currentTarget(_ observation: Observation) -> Target? {
        let identity = observation.state.identity
        guard let target = resolve(identity.workspaceID, identity.surfaceID),
              target.nativeOwner === observation.owner, target.store === observation.store,
              target.renderer === observation.renderer, target.sessionID == observation.sessionID,
              let current = state(target), sameState(observation.state, current),
              current.hasCompleteWorkEvidence else { return nil }
        return target
    }

    private func state(_ target: Target) -> ShepherdManagedSessionState? {
        guard target.store.managedCodingSessionID(for: target.nativeOwner) == target.sessionID,
              let state = target.store.managedCodingState(for: target.nativeOwner),
              state.identity.hostInstance == target.nativeOwner.scope.hostInstance,
              state.identity.workspaceID == target.nativeOwner.scope.workspaceID,
              state.identity.surfaceID == target.nativeOwner.scope.surfaceID,
              state.identity.surfaceGeneration == target.nativeOwner.scope.generation,
              state.identity.provider == target.nativeOwner.provider else { return nil }
        return state
    }

    private func sameTarget(_ left: Target, _ right: Target) -> Bool {
        left.nativeOwner === right.nativeOwner && left.store === right.store &&
            left.renderer === right.renderer && left.sessionID == right.sessionID
    }

    private func sameState(_ left: ShepherdManagedSessionState, _ right: ShepherdManagedSessionState) -> Bool {
        left.identity == right.identity && left.currentInputID == right.currentInputID &&
            left.currentInputOrigin == right.currentInputOrigin && left.eventRevision == right.eventRevision &&
            left.activityRevision == right.activityRevision && left.hasCompleteWorkEvidence == right.hasCompleteWorkEvidence
    }

    private func receipt(_ record: Record) -> ControlCallResult {
        .ok(.object([
            "protocol_version": .int(1), "receipt_version": .int(1),
            "host_instance": .string(record.identity.hostInstance.uuidString),
            "request_id": .string(record.requestID.uuidString), "identity": .object(encode(record.identity)),
            "state": .string(record.accepted ? "accepted" : record.editorAttempted ? "unknown" : "not_sent"),
            "reason": .string(record.reason), "editor_inserted": .bool(record.editorInserted),
            "backend_write_admitted": .bool(record.backendWriteAdmitted),
            "provider_acknowledged": .bool(record.providerInputID != nil),
            "provider_input_id": record.providerInputID.map(JSONValue.string) ?? .null,
        ]))
    }

    private func encode(_ identity: ShepherdManagedSessionIdentity) -> [String: JSONValue] {
        [
            "kind": .string("agent_session"), "host_instance": .string(identity.hostInstance.uuidString),
            "workspace_id": .string(identity.workspaceID.uuidString),
            "surface_id": .string(identity.surfaceID.uuidString), "provider": .string(identity.provider.rawValue),
            "provider_session_id": .string(identity.providerSessionID),
            "backend_pid": .int(Int64(identity.backendPID)), "backend_start_seconds": .int(identity.backendStartSeconds),
            "backend_start_microseconds": .int(Int64(identity.backendStartMicroseconds)),
            "surface_generation": Int64(exactly: identity.surfaceGeneration).map(JSONValue.int)
                ?? .decimal(String(identity.surfaceGeneration)),
            "executable_sha256": .string(identity.executableSHA256), "profile_sha256": .string(identity.profileSHA256),
        ]
    }

    private func uuid(_ value: JSONValue?) -> UUID? {
        guard case .string(let raw)? = value, raw.utf8.count == 36 else { return nil }
        return UUID(uuidString: raw)
    }

    private static func validText(_ text: String) -> Bool {
        !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines) &&
            text.count <= 2_000 && text.utf8.count <= 4_096 &&
            !text.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029
            }
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func failure(_ code: String) -> ControlCallResult {
        .err(code: code, message: "Managed Shepherd could not establish native input authority.", data: nil)
    }
}
