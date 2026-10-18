import CmuxControlSocket
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
        #expect(value.composer == .empty)
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
}
#endif
