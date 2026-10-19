import CmuxControlSocket
import CmuxFoundation
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) @MainActor
struct TerminalControllerShepherdWireCompositionTests {
    @Test func actualRelayRewriteCannotEnterGuardedInputAsALocalSocketPeer() async throws {
        let workspaceID = UUID()
        let rewriter = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: workspaceID, remoteRelayTokenHex: String(repeating: "ab", count: 32)
        )
        for method in ["surface.shepherd.inspect", "surface.shepherd.continue", "surface.shepherd.receipt"] {
            let command = Data(#"{"id":1,"method":"\#(method)","params":{"_cmux_remote_workspace_id":"forged-owner"}}"#.utf8)
            let forwarded = rewriter.rewriteRemoteRelayCommandLine(
                command, workspaceAliases: [:], surfaceAliases: [:]
            )
            guard case .success(let request) = ControlRequestParser().request(
                fromLine: String(decoding: forwarded, as: UTF8.self)
            ) else {
                Issue.record("The actual authenticated relay rewriter emitted an invalid request.")
                continue
            }
            #expect(request.params["_cmux_remote_workspace_id"] == .string(workspaceID.uuidString))
            let result = await TerminalController.shared.handleShepherdRequestAsync(
                request, peer: ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
            )
            guard case .err(let code, _, _) = result else {
                Issue.record("A relayed method reached guarded native observation.")
                continue
            }
            #expect(code == "access_denied")
        }
    }

    @Test func discoveryDoesNotClaimAnUnqualifiedEditorIsSafe() throws {
        let capabilities = TerminalController.shared.v2CapabilitiesWithBrowserDesignMode(params: [
            "shepherd_guarded_input": ["state": "qualified", "agents": ["claude", "codex"]]
        ])
        let shepherd = try #require(capabilities["shepherd_guarded_input"] as? [String: Any])
        #expect(shepherd["protocol_version"] as? Int == 1)
        #expect(shepherd["state"] as? String == "unqualified")
        #expect(shepherd["agents"] as? [String] == [])
        let methods = try #require(capabilities["methods"] as? [String])
        #expect(methods.contains("surface.shepherd.inspect"))
        #expect(methods.contains("surface.shepherd.continue"))
        #expect(methods.contains("surface.shepherd.receipt"))
        let remote = TerminalController.shared.v2CapabilitiesWithBrowserDesignMode(params: [
            "_cmux_remote_workspace_id": UUID().uuidString
        ])
        #expect(remote["shepherd_guarded_input"] == nil)
        #expect((remote["methods"] as? [String])?.contains { $0.hasPrefix("surface.shepherd.") } == false)
    }

    @Test func guardedWireNeverPublishesScreensTokensOrContinuationText() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        for method in ["surface.shepherd.inspect", "surface.shepherd.continue", "surface.shepherd.receipt"] {
            let request = #"{"method":" \n \#(method) \t","params":{"token":"opaque-sensitive-token","text":"private continuation"}}"#
            let response = #"{"ok":true,"result":{"screen":"private screen","token":"opaque-sensitive-token"}}"#
            CmuxSocketEventMapper.publish(command: request, response: response)
        }
        #expect(CmuxEventBus.shared.retainedSnapshot().isEmpty)
    }
}

// This suite also runs against the actual adapter source in the headless
// source harness, where only the app's lower terminal/workspace APIs are probes.
#if SHEPHERD_SOURCE_TEST
@Suite(.serialized) @MainActor
struct TerminalControllerShepherdHostTests {
    @Test func socketProvenanceCannotBeReplacedByRequestParameters() async {
        let owner = TerminalController()
        let request = ControlRequest(id: .int(4), method: "surface.shepherd.inspect", params: [
            "workspace_id": .string(UUID().uuidString), "surface_id": .string(UUID().uuidString)
        ])
        for peer in [
            nil,
            ShepherdControlPeer(peerHasSameUID: false, isRemoteRelay: false),
            ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: true)
        ] {
            let result = await owner.handleShepherdRequestAsync(request, peer: peer)
            guard case .err(let code, _, _) = result else {
                Issue.record("An unverified or remote caller reached native observation.")
                continue
            }
            #expect(code == "access_denied")
        }
        var relayParams = request.params
        relayParams["_cmux_remote_workspace_id"] = .string(UUID().uuidString)
        let relayed = ControlRequest(id: request.id, method: request.method, params: relayParams)
        let result = await owner.handleShepherdRequestAsync(
            relayed, peer: ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
        )
        guard case .err(let code, _, _) = result else {
            Issue.record("Relay provenance was stripped before guarded dispatch.")
            return
        }
        #expect(code == "access_denied")
    }

    @Test func localInspectionUsesOneBootAndNeverIssuesAnUnqualifiedToken() async throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let request = ControlRequest(id: .int(7), method: "surface.shepherd.inspect", params: [
            "workspace_id": .string(workspace.id.uuidString), "surface_id": .string(panel.id.uuidString)
        ])
        let peer = ShepherdControlPeer(peerHasSameUID: true, isRemoteRelay: false)
        let first = await owner.handleShepherdRequestAsync(request, peer: peer)
        let second = await owner.handleShepherdRequestAsync(request, peer: peer)
        guard case .ok(.object(let a)) = first, case .ok(.object(let b)) = second else {
            Issue.record("Same-user exact-target inspection was not routed.")
            return
        }
        #expect(a["protocol_version"] == .int(1))
        #expect(a["host_instance"] == b["host_instance"])
        #expect(a["token"] == .null)
        #expect(a["screen"] == .string("abc"))
        #expect(TerminalController.isShepherdSocketCommand(
            #"{"method":" \n surface.shepherd.continue \t","params":{}}"#
        ))
        #expect(!TerminalController.isShepherdSocketCommand(
            #"{"method":"surface.send_text","params":{}}"#
        ))
    }

    @Test func exactWorkspaceAndOwningTabAreRequired() {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let host = TerminalControllerShepherdHost(owner: owner)
        #expect(host.snapshot(workspaceID: UUID(), surfaceID: panel.id) == nil)
        panel.surface.owningTabId = UUID()
        #expect(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id) == nil)
        #expect(panel.surface.pastes.isEmpty)
    }

    @Test func missingNativeEvidenceNeverBecomesReady() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let host = TerminalControllerShepherdHost(owner: owner)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.screenFingerprint == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(value.processInstance == nil)
        #expect(value.agent == nil)
        #expect(value.workingDirectory == nil)
        #expect(value.tty == nil)
        #expect(value.idle == nil)
        #expect(value.backgroundWork == nil)
        #expect(value.outsideComposerFingerprint.isEmpty)
        #expect(value.composer == .unknown)
        #expect(!value.focused)
    }

    @Test func adapterRejectsChangedObservationBeforeCallingNativeWriter() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let host = TerminalControllerShepherdHost(owner: owner)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        let intent = ShepherdContinuationRequest(requestID: UUID(), tokenID: UUID(), text: "Continue the work.")
        panel.surface.shepherdInputRevision += 1
        #expect(host.paste(request: intent, snapshot: value, expiresAt: 2) == .notAdmitted)
        #expect(!host.submit(requestID: intent.requestID, snapshot: value))
        #expect(panel.surface.pastes.isEmpty)
        #expect(panel.surface.submits.isEmpty)
    }

    @Test func releaseDoesNotFindAnotherWorkspaceOrRecreateSurface() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let host = TerminalControllerShepherdHost(owner: owner)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        workspace.id = UUID()
        host.releaseReservation(requestID: UUID(), snapshot: value)
        #expect(panel.surface.releases.isEmpty)
    }

    @Test func boundNativeProcessFactsReachInspectionWithoutInventingReadiness() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.processInstance == "42:123456")
        #expect(value.agent == "claude")
        #expect(value.workingDirectory == "/private/tmp")
        #expect(value.tty == "/dev/ttys123")
        #expect(value.idle == nil)
        #expect(value.backgroundWork == nil)
        #expect(value.outsideComposerFingerprint.isEmpty)
    }

    @Test func processChangedWhileReadingScreenCannotRetainOldProcessProof() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        panel.surface.onReadScreen = { fixture.executable = "/opt/bin/codex" }
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.processInstance == nil)
        #expect(value.agent == nil)
        #expect(value.workingDirectory == nil)
        #expect(value.tty == nil)
    }

    @Test func changedProcessProofWithholdsPasteAndSubmit() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        fixture.executable = "/opt/bin/codex"
        let request = ShepherdContinuationRequest(requestID: UUID(), tokenID: UUID(), text: "Continue.")
        #expect(!host.submit(requestID: request.requestID, snapshot: value))
        #expect(host.paste(request: request, snapshot: value, expiresAt: 2) == .notAdmitted)
        #expect(panel.surface.pastes.isEmpty)
        #expect(panel.surface.submits.isEmpty)
    }

    @Test func guardedComposerAndOutsideHashUseTheSameStrictGridNotLegacyEmpty() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        panel.surface.renderFrame = try shepherdRenderFrame(surfaceID: panel.id, draft: "Human draft")
        var captures = 0
        panel.surface.onReadGrid = { captures += 1 }
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.composer == .draft("Human draft"))
        #expect(value.outsideComposerFingerprint.count == 64)
        #expect(captures == 1)
        #expect(value.idle == nil)
        #expect(value.backgroundWork == nil)
    }

    @Test func changedRawScreenWhileCapturingGridCannotMintRenderProof() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        panel.surface.renderFrame = try shepherdRenderFrame(surfaceID: panel.id)
        panel.surface.onReadGrid = { panel.surface.screen = "Output changed during the grid capture." }
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.composer == .unknown)
        #expect(value.screenFingerprint == "")
        #expect(value.outsideComposerFingerprint == "")
    }

    @Test func aGridFromAnotherSurfaceCannotDonateComposerProof() throws {
        let owner = TerminalController()
        let workspace = Workspace()
        let panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        panel.surface.renderFrame = try shepherdRenderFrame(surfaceID: UUID())
        AppDelegate.shared = AppDelegate(workspace: workspace)
        let fixture = ProcessFixture()
        let host = TerminalControllerShepherdHost(owner: owner, processEvidenceReader: fixture.reader)
        let value = try #require(host.snapshot(workspaceID: workspace.id, surfaceID: panel.id))
        #expect(value.composer == .unknown)
        #expect(value.outsideComposerFingerprint == "")
    }

    @Test func exactCurrentRootProofMakesReadinessKnownAndNonceChangesInvalidateSnapshots() throws {
        let fixture = try ReadinessFixture()
        let value = try #require(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ))
        #expect(value.idle == true)
        #expect(value.backgroundWork == false)
        #expect(value.composer == .empty)
        fixture.data = try fixture.store()
        let next = try #require(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ))
        #expect(next.idle == true)
        #expect(next.outsideComposerFingerprint != value.outsideComposerFingerprint)
        #expect(fixture.host.paste(
            request: ShepherdContinuationRequest(requestID: UUID(), tokenID: UUID(), text: "Continue."),
            snapshot: value, expiresAt: ProcessInfo.processInfo.systemUptime + 1
        ) == .notAdmitted)
        #expect(fixture.panel.surface.pastes.isEmpty)
    }

    @Test(arguments: ["missing", "input", "boot", "birth", "during-capture"])
    func readinessCannotOutliveItsFileAndNativeEpoch(change: String) throws {
        let fixture = try ReadinessFixture()
        switch change {
        case "missing": fixture.data = nil
        case "input": fixture.panel.surface.invalidateShepherdInput()
        case "boot": fixture.data = try fixture.store(boot: UUID())
        case "birth": fixture.process.birth = AgentPIDProcessIdentity(
            pid: 42, startSeconds: 999, startMicroseconds: 200
        )
        default: fixture.panel.surface.onReadGrid = { fixture.data = nil }
        }
        let value = try #require(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ))
        #expect(value.idle == nil)
        #expect(value.backgroundWork == nil)
    }

    @Test func realPasteAndBothPostPasteReadsRetainProofUntilSingleEnterConsumesIt() throws {
        let fixture = try ReadinessFixture()
        let expected = try #require(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ))
        let request = ShepherdContinuationRequest(requestID: UUID(), tokenID: UUID(), text: "Continue.")
        #expect(fixture.host.paste(
            request: request, snapshot: expected, expiresAt: ProcessInfo.processInfo.systemUptime + 1
        ) == .admitted(inputRevision: 10))
        fixture.panel.surface.renderFrame = try shepherdRenderFrame(
            surfaceID: fixture.panel.id, draft: "Continue."
        )
        let after = try #require(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ))
        #expect(after.idle == true)
        #expect(after.backgroundWork == false)
        #expect(after.inputRevision == 10)
        #expect(after.outsideComposerFingerprint == expected.outsideComposerFingerprint)
        #expect(fixture.host.submit(requestID: request.requestID, snapshot: after))
        #expect(!fixture.host.submit(requestID: request.requestID, snapshot: after))
        #expect(fixture.panel.surface.pastes == ["Continue."])
        #expect(fixture.panel.surface.submits.count == 1)
        #expect(fixture.host.snapshot(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        )?.idle == nil)
    }

    @Test func completeEvidenceDoesNotQualifyTheDefaultProductionHost() throws {
        let fixture = try ReadinessFixture()
        let host = TerminalControllerShepherdHost(
            owner: fixture.owner, processEvidenceReader: fixture.process.reader, hostInstance: fixture.boot,
            readinessStoreData: { fixture.data }
        )
        let controller = ShepherdAdmissionController(
            host: host, now: { ProcessInfo.processInfo.systemUptime }, wait: { _ in }
        )
        let inspection = try controller.inspect(workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id)
        #expect(inspection.snapshot.idle == true)
        #expect(inspection.snapshot.backgroundWork == false)
        #expect(inspection.token == nil)
        #expect(!inspection.snapshot.acceptsImmediateInput)
        #expect(host.paste(
            request: ShepherdContinuationRequest(requestID: UUID(), tokenID: UUID(), text: "Continue."),
            snapshot: inspection.snapshot, expiresAt: ProcessInfo.processInfo.systemUptime + 1
        ) == .notAdmitted)
        #expect(fixture.panel.surface.pastes.isEmpty)
    }

    @Test func controllerUsesRepeatedProofReadsWithoutMintingATokenDuringOwnedPaste() async throws {
        let fixture = try ReadinessFixture()
        var clock = ProcessInfo.processInfo.systemUptime
        var controller: ShepherdAdmissionController!
        controller = ShepherdAdmissionController(host: fixture.host, now: { clock }, wait: { seconds in
            #expect(try controller.inspect(
                workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
            ).token == nil)
            fixture.panel.surface.renderFrame = try shepherdRenderFrame(
                surfaceID: fixture.panel.id, draft: "Continue."
            )
            clock += seconds
        })
        let token = try #require(controller.inspect(
            workspaceID: fixture.workspace.id, surfaceID: fixture.panel.id
        ).token)
        let request = ShepherdContinuationRequest(requestID: UUID(), tokenID: token.id, text: "Continue.")
        let receipt = try await controller.continueInput(request)
        #expect(receipt.state == .accepted)
        #expect(try await controller.continueInput(request) == receipt)
        #expect(fixture.panel.surface.pastes == ["Continue."])
        #expect(fixture.panel.surface.submits.count == 1)
    }
}

@MainActor private final class ReadinessFixture {
    let workspace = Workspace()
    let owner = TerminalController()
    let panel: TerminalPanel
    let process = ProcessFixture()
    let boot = UUID()
    var data: Data?
    lazy var host = TerminalControllerShepherdHost(
        owner: owner, processEvidenceReader: process.reader, hostInstance: boot,
        readinessStoreData: { [unowned self] in self.data }, qualifiedAgents: ["claude"]
    )

    init() throws {
        panel = TerminalPanel(workspaceID: workspace.id)
        workspace.panels[panel.id] = panel
        panel.surface.foregroundPID = 42
        panel.surface.shepherdInputRevision = 9
        panel.surface.renderFrame = try shepherdRenderFrame(surfaceID: panel.id)
        AppDelegate.shared = AppDelegate(workspace: workspace)
        data = try store()
    }

    func store(boot: UUID? = nil) throws -> Data {
        let scope = ShepherdHookReadinessScope(
            hostInstance: boot ?? self.boot, workspaceID: workspace.id, surfaceID: panel.id,
            processInstance: "42:123456", pid: 42, pidStartSeconds: process.birth.startSeconds,
            pidStartMicroseconds: process.birth.startMicroseconds, surfaceGeneration: 1, inputRevision: 9
        )
        let proof = try #require(ShepherdHookReadinessProof(
            stopInput: ["background_tasks": [], "session_crons": []], sessionID: "root", scope: scope
        ))
        return try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": ["root": [
                "sessionId": "root", "workspaceId": workspace.id.uuidString,
                "surfaceId": panel.id.uuidString, "pid": 42,
                "pidStartSeconds": process.birth.startSeconds,
                "pidStartMicroseconds": process.birth.startMicroseconds,
                "hookEventName": "Stop", "turnSettled": true, "activePromptDepth": 0,
                "shepherdReadiness": try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))
            ]],
            "activeSessionsBySurface": [panel.id.uuidString: ["sessionId": "root"]]
        ])
    }
}
#endif
