import CmuxControlSocket
import CmuxFoundation
import Darwin
import Foundation

/// A provider-bound native object capability, never decoded from bridge or provider data.
@MainActor
final class AgentSessionManagedNativeOwner {
    enum ProfileError: Error {
        case nativeProfileUnqualified
    }

    struct Scope: Equatable {
        let hostInstance: UUID
        let workspaceID: UUID
        let surfaceID: UUID
        let generation: UInt64
    }

    private enum ProfileRequirement {
        case qualifiedNativeProfile
        #if SHEPHERD_SOURCE_TEST
        case controlledSourceFixture
        #endif
    }

    private struct QualifiedNativeProfile: Hashable {
        let provider: ShepherdManagedProvider
        let executableSHA256: String
        let profileSHA256: String
        let rendererID: String
    }
    private static let qualifiedNativeProfiles: Set<QualifiedNativeProfile> = []

    static func hasQualifiedNativeProfile(
        rendererID: String, provider: ShepherdManagedProvider = .copilot
    ) -> Bool {
        qualifiedNativeProfiles.contains { $0.provider == provider && $0.rendererID == rendererID }
    }

    static let executionDisclosure =
        "General-purpose foreground coding commands run as your OS account, with no sandbox " +
        "and no per-call SDK permission prompt. They can access or change files and use the network " +
        "where your account has access. The project folder is a working directory, not confinement."
    private static let hostInstance = UUID()
    let provider: ShepherdManagedProvider
    let scope: Scope
    let projectMandate = UUID()
    let workingDirectory: String
    let rendererID: String
    private let host: AgentPIDProcessIdentity
    private weak var owningStore: AnyObject?
    private let isCurrentOwner: @MainActor () -> Bool
    private weak var lifetime: AgentSessionManagedSession?
    private var consumed = false
    private var revoked = false
    private var revocationSink: (() -> Void)?
    private let profileRequirement: ProfileRequirement

    static func issueForFreshNativePanel(
        newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
        owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool,
        provider: ShepherdManagedProvider = .copilot
    ) -> AgentSessionManagedNativeOwner? {
        AgentSessionManagedNativeOwner(
            newPanelID: newPanelID, workspaceID: workspaceID, rendererID: rendererID,
            workingDirectory: workingDirectory, owningStore: owningStore,
            isCurrentOwner: isCurrentOwner, provider: provider, profileRequirement: .qualifiedNativeProfile
        )
    }

    #if SHEPHERD_SOURCE_TEST
    convenience init?(
        newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
        owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool,
        provider: ShepherdManagedProvider = .copilot
    ) {
        self.init(
            newPanelID: newPanelID, workspaceID: workspaceID, rendererID: rendererID,
            workingDirectory: workingDirectory, owningStore: owningStore,
            isCurrentOwner: isCurrentOwner, provider: provider, profileRequirement: .controlledSourceFixture
        )
    }
    #endif

    private init?(
        newPanelID: UUID, workspaceID: UUID, rendererID: String, workingDirectory: String,
        owningStore: AnyObject, isCurrentOwner: @escaping @MainActor () -> Bool,
        provider: ShepherdManagedProvider, profileRequirement: ProfileRequirement
    ) {
        guard ["react", "solid"].contains(rendererID),
              let host = AgentPIDProcessIdentity(pid: getpid()),
              let directory = try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory),
              isCurrentOwner() else { return nil }
        self.provider = provider
        self.scope = Scope(
            hostInstance: Self.hostInstance, workspaceID: workspaceID, surfaceID: newPanelID, generation: 1
        )
        self.workingDirectory = directory
        self.rendererID = rendererID
        self.host = host
        self.owningStore = owningStore
        self.isCurrentOwner = isCurrentOwner
        self.profileRequirement = profileRequirement
    }

    func consume(
        for store: AnyObject, scope: Scope, workingDirectory: String, projectMandate: UUID
    ) -> Bool {
        guard !consumed, owningStore === store, self.scope == scope,
              self.projectMandate == projectMandate,
              (try? AgentSessionManagedCopilotLaunch.canonicalPath(workingDirectory)) == self.workingDirectory,
              isCurrent else {
            revoke()
            return false
        }
        consumed = true
        return true
    }

    func installRevocationSink(for store: AnyObject, _ sink: @escaping () -> Void) -> Bool {
        guard consumed, owningStore === store, revocationSink == nil, isCurrent else { return false }
        revocationSink = sink
        return true
    }

    func bind(to lifetime: AgentSessionManagedSession) -> Bool {
        guard consumed, self.lifetime == nil, isCurrent, matches(lifetime) else {
            revoke()
            return false
        }
        self.lifetime = lifetime
        return true
    }

    private func matches(_ lifetime: AgentSessionManagedSession) -> Bool {
        lifetime.declaredProvider == provider && lifetime.ownsWorkingDirectory(workingDirectory) &&
            lifetime.ownsNativeScope(
                hostInstance: scope.hostInstance, workspaceID: scope.workspaceID,
                surfaceID: scope.surfaceID, generation: scope.generation
            )
    }

    var isCurrent: Bool {
        !revoked && owningStore != nil && AgentPIDProcessIdentity(pid: getpid()) == host && isCurrentOwner()
    }

    func authorizes(_ lifetime: AgentSessionManagedSession) -> Bool {
        consumed && self.lifetime === lifetime && matches(lifetime) && isCurrent
    }

    func requireQualifiedProfile(executableSHA256: String, profileSHA256: String) throws {
        switch profileRequirement {
        case .qualifiedNativeProfile:
            guard Self.qualifiedNativeProfiles.contains(QualifiedNativeProfile(
                provider: provider, executableSHA256: executableSHA256,
                profileSHA256: profileSHA256, rendererID: rendererID
            )) else { throw ProfileError.nativeProfileUnqualified }
        #if SHEPHERD_SOURCE_TEST
        case .controlledSourceFixture:
            break
        #endif
        }
    }

    func revoke() {
        guard !revoked else { return }
        revoked = true
        revocationSink?()
    }
}
