/// Installed runtime evidence cannot substitute for causal native-input attribution.
public enum ShepherdHookLaunchPolicy {
    public static let testedBinaries: [String: Set<String>] = [:]
    // A profile or stable native read cannot close this; the agent protocol
    // must supply a trusted correlation to the original native input.
    public static let qualificationBlocker: String? = "claude_native_input_attribution_unavailable"

    public static var qualifiedBinaries: [String: Set<String>] {
        qualificationBlocker == nil ? testedBinaries : [:]
    }

    public static var qualifiedAgents: Set<String> {
        qualifiedBinaries.isEmpty ? [] : ["claude"]
    }
}
