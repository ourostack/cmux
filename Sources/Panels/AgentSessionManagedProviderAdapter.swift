import CmuxControlSocket
import Foundation

struct AgentSessionManagedInputProgress {
    let inputID: UUID
    let identity: ShepherdManagedSessionIdentity
    let editorInserted = true
    var backendWriteAdmitted = false
    var providerInputID: String?
    var failureReason: String?

    func matches(
        inputID: UUID, identity: ShepherdManagedSessionIdentity,
        backendWriteAdmitted: Bool, providerInputID: String?
    ) -> Bool {
        self.inputID == inputID && self.identity == identity && editorInserted &&
            (!backendWriteAdmitted || self.backendWriteAdmitted) &&
            (providerInputID == nil || providerInputID == self.providerInputID)
    }
}

@MainActor
protocol AgentSessionManagedProviderAdapter: AnyObject {
    var configurationObserved: Bool { get }
    var inputState: ShepherdManagedSessionState? { get }
    var hasCompleteWorkEvidence: Bool { get }
    var failureSink: ((String) -> Void)? { get set }
    var projectionSink: ((AgentSessionManagedProjection) -> Void)? { get set }

    func submitOwnerInput(_ inputID: UUID, prompt: String, launchID: UUID) -> Bool
    func beginSupervisorInput(
        _ submission: AgentSessionManagedRendererController.Submission,
        nativeOwner: AgentSessionManagedNativeOwner, owningStore: AnyObject,
        progress: ((AgentSessionManagedInputProgress) -> Void)?
    ) -> Bool
    func supervisorInputProgress(_ inputID: UUID) -> AgentSessionManagedInputProgress?
}
