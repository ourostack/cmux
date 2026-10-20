import type { ProviderId, ProviderInfo } from "./types";

const managedCopilotPresentation: ProviderInfo = {
  id: "copilot",
  displayName: "GitHub Copilot",
  executableName: "copilot",
  transportKind: "managed-stdio-jsonrpc",
  arguments: [],
  autoStart: false,
};

export function selectedProviderForDisplay(providers: ProviderInfo[], selectedProviderId: ProviderId): ProviderInfo | undefined {
  return providers.find((provider) => provider.id === selectedProviderId) ??
    (selectedProviderId === "copilot" ? managedCopilotPresentation : undefined);
}

export function codexModelLabel(provider: Pick<ProviderInfo, "displayName" | "id"> | undefined): string {
  if (provider?.id === "codex") {
    return "GPT-5.5";
  }
  return provider?.displayName ?? "GPT-5.5";
}

export function providerBadgeLabel(provider: Pick<ProviderInfo, "displayName" | "id">): string {
  const displayName = provider.displayName;
  const lower = displayName.toLowerCase();
  if (provider.id === "claude" || lower.includes("claude")) {
    return "Cl";
  }
  if (provider.id === "opencode" || lower.includes("open")) {
    return "O";
  }
  if (lower === "pi" || lower.includes(" pi")) {
    return "Pi";
  }
  return displayName.trim().slice(0, 1).toUpperCase() || "C";
}
