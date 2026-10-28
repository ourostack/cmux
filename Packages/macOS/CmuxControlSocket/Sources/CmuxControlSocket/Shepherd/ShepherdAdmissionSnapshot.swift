public import Foundation

/// Native target evidence used to refuse changed or unknown input conditions.
///
/// Construct this from current host observations, not caller assertions or
/// terminal instructions. Unknown optional facts never mean idle or ready.
public struct ShepherdAdmissionSnapshot: Equatable, Sendable {
    /// The exact native surface whose input is being considered.
    public var surfaceID: UUID
    /// The workspace that currently owns the surface.
    public var workspaceID: UUID
    /// The native foreground-process identity, or nil when unverified.
    public var processInstance: String?
    /// The agent verified in this native process scope, not a hook or PS hint.
    public var agent: String?
    /// This process's verified current directory, or nil when unverified.
    public var workingDirectory: String?
    /// The terminal bound to this process observation, or nil when unverified.
    public var tty: String?
    /// The native runtime generation that must not change during admission.
    public var surfaceGeneration: UInt64
    /// The current screen fingerprint, empty when unavailable.
    public var screenFingerprint: String
    /// A verified fingerprint outside the composer, empty when unavailable.
    public var outsideComposerFingerprint: String
    /// The native input revision, including physical or competing input.
    public var inputRevision: UInt64
    /// The native revision for focus or selection changes.
    public var focusRevision: UInt64
    /// Whether the host positively reports this target as focused.
    public var focused: Bool
    /// Positive idle or busy evidence, or nil when unavailable.
    public var idle: Bool?
    /// The current recognized composer, including unknown or dialog states.
    public var composer: ShepherdComposerState
    /// Positive background-work evidence, or nil rather than an assumed false.
    public var backgroundWork: Bool?
    /// Whether this target admits live input without creation or queuing.
    public var acceptsImmediateInput: Bool

    /// Creates a value snapshot without establishing input authority.
    ///
    /// - Parameters:
    ///   - surfaceID: The exact native surface.
    ///   - workspaceID: Its current owning workspace.
    ///   - processInstance: A verified foreground instance, or nil.
    ///   - surfaceGeneration: The current native runtime generation.
    ///   - screenFingerprint: The observed screen fingerprint.
    ///   - outsideComposerFingerprint: Verified content outside the composer.
    ///   - inputRevision: The native input counter.
    ///   - focusRevision: The native focus and selection counter.
    ///   - focused: Known current focus; refuse the observation if unknowable.
    ///   - idle: Positive idle or busy evidence, or nil.
    ///   - composer: The recognized input area's actual state.
    ///   - backgroundWork: Known work status; absence must remain nil.
    ///   - acceptsImmediateInput: Known zero-queue readiness.
    ///   - agent: The natively verified agent, never an independent client guess.
    ///   - workingDirectory: The directory bound to this same native process.
    ///   - tty: The terminal bound to this same native process.
    public init(
        surfaceID: UUID,
        workspaceID: UUID,
        processInstance: String?,
        surfaceGeneration: UInt64,
        screenFingerprint: String,
        outsideComposerFingerprint: String,
        inputRevision: UInt64,
        focusRevision: UInt64,
        focused: Bool,
        idle: Bool?,
        composer: ShepherdComposerState,
        backgroundWork: Bool?,
        acceptsImmediateInput: Bool,
        agent: String? = nil,
        workingDirectory: String? = nil,
        tty: String? = nil
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.processInstance = processInstance
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.surfaceGeneration = surfaceGeneration
        self.screenFingerprint = screenFingerprint
        self.outsideComposerFingerprint = outsideComposerFingerprint
        self.inputRevision = inputRevision
        self.focusRevision = focusRevision
        self.focused = focused
        self.idle = idle
        self.composer = composer
        self.backgroundWork = backgroundWork
        self.acceptsImmediateInput = acceptsImmediateInput
    }
}
