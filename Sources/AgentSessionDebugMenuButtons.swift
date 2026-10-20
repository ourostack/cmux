import SwiftUI

#if DEBUG
struct AgentSessionDebugMenuButtons: View {
    let openReact: () -> Void
    let openSolid: () -> Void
    let openManagedReact: () -> Void
    let openManagedSolid: () -> Void

    var body: some View {
        Button(
            String(
                localized: "debug.menu.openAgentGuiReact",
                defaultValue: "Open Agent GUI (React)"
            )
        ) {
            openReact()
        }

        Button(
            String(
                localized: "debug.menu.openAgentGuiSolid",
                defaultValue: "Open Agent GUI (Solid)"
            )
        ) {
            openSolid()
        }

        Button(
            String(localized: "debug.menu.openManagedCopilotReact", defaultValue: "Open Managed Copilot (React)...")
        ) {
            openManagedReact()
        }
        .disabled(!AgentSessionManagedCopilotLaunch.NativeCodingOwner.hasQualifiedNativeProfile(rendererID: "react"))
        .help(String(
            localized: "debug.menu.managedCopilotQualification",
            defaultValue: "Requires a qualified native Copilot binary, launch profile, and renderer."
        ))

        Button(
            String(localized: "debug.menu.openManagedCopilotSolid", defaultValue: "Open Managed Copilot (Solid)...")
        ) {
            openManagedSolid()
        }
        .disabled(!AgentSessionManagedCopilotLaunch.NativeCodingOwner.hasQualifiedNativeProfile(rendererID: "solid"))
        .help(String(
            localized: "debug.menu.managedCopilotQualification",
            defaultValue: "Requires a qualified native Copilot binary, launch profile, and renderer."
        ))
    }
}
#endif
