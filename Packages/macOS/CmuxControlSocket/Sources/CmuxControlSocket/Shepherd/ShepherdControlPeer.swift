/// Socket-owned provenance, captured before automation or relay rewriting.
///
/// Never construct this from request parameters. Unknown socket identity is
/// represented by a nil peer at the boundary and is refused.
public struct ShepherdControlPeer: Sendable {
    /// Whether the accepted socket's native peer has the owner's UID.
    public let peerHasSameUID: Bool
    /// Whether this request arrived through a remote workspace relay.
    public let isRemoteRelay: Bool

    /// Creates provenance from the accepted connection, not caller assertions.
    public init(peerHasSameUID: Bool, isRemoteRelay: Bool) {
        self.peerHasSameUID = peerHasSameUID
        self.isRemoteRelay = isRemoteRelay
    }
}
