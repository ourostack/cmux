import SwiftUI

#if DEBUG
struct AgentSessionDebugMenuButtons: View {
    let openReact: () -> Void
    let openSolid: () -> Void
    let openManagedReact: () -> Void
    let openManagedSolid: () -> Void
    let openManagedCodexReact: () -> Void
    let openManagedCodexSolid: () -> Void

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

        Button(
            String(localized: "debug.menu.openManagedCodexReact", defaultValue: "Open Managed Codex (React)...")
        ) {
            openManagedCodexReact()
        }
        .disabled(!AgentSessionManagedCopilotLaunch.NativeCodingOwner.hasQualifiedNativeProfile(
            rendererID: "react", provider: .codex
        ))
        .help(String(
            localized: "debug.menu.managedCodexQualification",
            defaultValue: "Requires a qualified owned Codex backend, launch profile, and renderer."
        ))

        Button(
            String(localized: "debug.menu.openManagedCodexSolid", defaultValue: "Open Managed Codex (Solid)...")
        ) {
            openManagedCodexSolid()
        }
        .disabled(!AgentSessionManagedCopilotLaunch.NativeCodingOwner.hasQualifiedNativeProfile(
            rendererID: "solid", provider: .codex
        ))
        .help(String(
            localized: "debug.menu.managedCodexQualification",
            defaultValue: "Requires a qualified owned Codex backend, launch profile, and renderer."
        ))

    }
}
#endif
