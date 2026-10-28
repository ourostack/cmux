import Foundation

// Only the unexercised manual-launch setting is doubled; managed Store code stays actual.
public struct AutomationCatalogSection {
    public struct UnusedScratchSetting {
        public func value(in defaults: UserDefaults) -> Bool {
            fatalError("manual-launch settings must not be read by these managed Store scenarios")
        }
    }
    public let canonicalAgentScratch = UnusedScratchSetting()
    public init() {}
}
