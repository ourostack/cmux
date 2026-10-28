/// Native facts plus an optional token; missing authority never means ready.
public struct ShepherdAdmissionInspection: Equatable, Sendable {
    /// The current host-owned observation, including unknown readiness facts.
    public let snapshot: ShepherdAdmissionSnapshot
    /// A short-lived token, or nil when the observation cannot admit input.
    public let token: ShepherdObservationToken?
}
