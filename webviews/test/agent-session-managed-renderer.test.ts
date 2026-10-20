import { beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { readFileSync } from "node:fs";
import type { AgentEvent, AppContext, NativeManagedSession, RendererKind } from "../src/agent-session/shared/types";

const disclosure =
  "General-purpose foreground coding commands run as your OS account, with no sandbox " +
  "and no per-call SDK permission prompt. They can access or change files and use the network " +
  "where your account has access. The project folder is a working directory, not confinement.";

const copy: AppContext["copy"] = {
  start: "Start", stop: "Stop", send: "Send", provider: "Provider", rateLimits: "Rate limits",
  rateLimitUsageRemaining: "Usage remaining", rateLimitPrimary: "Primary", rateLimitSecondary: "Secondary",
  rateLimitWeekly: "Weekly", rateLimitMonthly: "Monthly", rateLimitDaysFormat: "%@d",
  rateLimitHoursFormat: "%@h", rateLimitMinutesFormat: "%@m", rateLimitResets: "resets",
  voiceInput: "Voice input", promptPlaceholder: "Owner prompt", attachFile: "Attach file",
  addFilesAndMore: "Add files", addPhotosAndFiles: "Add photos and files", removeAttachment: "Remove attachment",
  copyOutput: "Copy output", copyAssistantMessage: "Copy", copiedAssistantMessage: "Copied",
  copyUserMessage: "Copy message", copiedUserMessage: "Copied", shellLabel: "Shell", copyShellContents: "Copy shell",
  copiedShellContents: "Copied", collapseShell: "Collapse", shellSuccess: "Success", showMore: "Show more",
  showLess: "Show less", browseWeb: "Browse web", autoContext: "Context", includeIdeContext: "Include context",
  ideContext: "IDE context", tools: "Tools", changePermissions: "Change permissions", permissionsDefault: "Default",
  permissionsFullAccess: "Full access", permissionsAutoReview: "Auto-review", permissionsCustom: "Custom",
  reasoningEffortHigh: "High", mentionMenuTitle: "Mention", mentionCurrentWorkspace: "Current workspace",
  skillMenuTitle: "Skills", composerNoResults: "No results", planMode: "Plan mode",
  planSuggestionAction: "Use plan", planSuggestionDismiss: "Dismiss", planSuggestionShortcut: "Shift+Tab",
  planSuggestionTitle: "Create a plan", skillPlan: "Plan", skillCodeReview: "Code review", skillResearch: "Research",
  loadingStatus: "Loading", idleStatus: "Idle", startingStatus: "Starting", runningStatus: "Running",
  stoppingStatus: "Stopping", failedStatus: "Failed", rendererReadyFormat: "%@ ready", stopped: "Stopped",
  sentCharsFormat: "Sent %d chars", providerStarted: "Provider started", providerExitedFormat: "Provider exited %d",
  requestFailed: "Native request failed",
};

const bundles = new Map<RendererKind, string>();

beforeAll(async () => {
  for (const [renderer, entrypoint] of [
    ["react", "test/fixtures/agent-session-react-entry.ts"],
    ["solid", "src/agent-session/solid/main.ts"],
  ] as const) {
    const result = await Bun.build({
      entrypoints: [entrypoint],
      target: "browser",
      format: "iife",
      conditions: ["browser"],
      define: { "process.env.NODE_ENV": '"development"' },
    });
    if (!result.success) throw new AggregateError(result.logs, `Actual ${renderer} source bundling failed.`);
    const output = result.outputs.find((artifact) => artifact.kind === "entry-point");
    if (!output) throw new Error(`Missing actual ${renderer} entrypoint output.`);
    bundles.set(renderer, await output.text());
  }
});

function mount(renderer: RendererKind, nativeSession?: NativeManagedSession, earlyEvents: AgentEvent[] = []) {
  const errors: string[] = [];
  const messages: string[] = [];
  const console = new VirtualConsole();
  console.on("jsdomError", (error) => errors.push(String(error)));
  const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "https://cmux.invalid/agent-session.html",
    runScripts: "outside-only",
    pretendToBeVisual: true,
    virtualConsole: console,
  });
  dom.window.addEventListener("error", (event) => errors.push(String(event.error ?? event.message)));
  const context: AppContext = {
    panelId: "controlled-panel", workspaceId: "controlled-workspace", renderer,
    initialProviderId: "copilot", workingDirectory: "/controlled/project", copy, nativeSession,
    theme: {
      isDark: true, pageBackground: "#111", surfaceBackground: "#222", surfaceElevatedBackground: "#333",
      inputBackground: "#111", border: "#444", borderStrong: "#555", text: "#fff", mutedText: "#aaa",
      softText: "#bbb", accent: "#acf", accentSoft: "#345", danger: "#f88", shadow: "#000",
    },
  };
  Object.defineProperty(dom.window, "webkit", {
    value: { messageHandlers: { agentSession: {
      async postMessage(request: { method: string }) {
        messages.push(request.method);
        if (request.method === "app.context") return { ok: true, value: context };
        if (request.method === "provider.list") {
          await new Promise((resolve) => setTimeout(resolve, 5));
          for (const event of earlyEvents) dom.window.cmuxAgentBridge?.receive(event);
          return { ok: true, value: [] };
        }
        if (request.method === "provider.stop") return { ok: true, value: { stopped: true } };
        throw new Error(`Unexpected native operation: ${request.method}`);
      },
    } } },
  });
  const source = bundles.get(renderer);
  if (!source) throw new Error(`Missing built ${renderer} fixture.`);
  dom.window.eval(readFileSync(new URL("../../Resources/markdown-viewer/marked.min.js", import.meta.url), "utf8"));
  dom.window.eval(source);
  return { dom, errors, messages };
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = performance.now() + 1000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("Actual renderer did not reach the expected DOM state.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

for (const renderer of ["react", "solid"] as const) {
  test(`actual ${renderer} renderer recovers native ownership and visibly discloses command authority`, async () => {
    const fixture = mount(renderer, {
      providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2, executionDisclosure: disclosure,
    });
    try {
      await waitFor(() => Array.from(fixture.dom.window.document.querySelectorAll("button"))
        .some((button) => button.getAttribute("aria-label") === "Stop" && !button.disabled && !button.hidden));
      expect(fixture.errors).toEqual([]);
      expect(fixture.dom.window.document.body.textContent).toContain(disclosure);
      expect(fixture.dom.window.document.body.textContent).toContain("GitHub Copilot");
      expect(fixture.dom.window.document.body.textContent).not.toContain("GPT-5.5");
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} renderer does not turn a restored Copilot panel into a manual start`, async () => {
    const fixture = mount(renderer);
    try {
      await waitFor(() => fixture.messages.includes("app.context") && fixture.messages.includes("provider.list")
        && fixture.dom.window.document.querySelector("form") != null);
      expect(fixture.errors).toEqual([]);
      expect(Array.from(fixture.dom.window.document.querySelectorAll("button"))
        .some((button) => button.textContent?.trim() === "Start" && !button.disabled)).toBe(false);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} renderer reconciles native events racing its initial snapshot`, async () => {
    const fixture = mount(renderer, {
      providerId: "copilot", sessionId: "native-owned-session", status: "starting", revision: 1, executionDisclosure: disclosure,
    }, [
      {
        type: "provider.started", providerId: "copilot", sessionId: "native-owned-session",
        executablePath: "/native/copilot", arguments: ["--headless"],
        nativeSession: {
          providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
          executionDisclosure: disclosure,
        },
      },
      {
        type: "provider.output", providerId: "copilot", sessionId: "native-owned-session", stream: "stdout",
        text: "Native output after the captured snapshot",
      },
    ]);
    try {
      await waitFor(() => fixture.dom.window.document.body.textContent?.includes(
        "Native output after the captured snapshot",
      ) === true);
      expect(fixture.errors).toEqual([]);
      expect(fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled).toBe(false);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} renderer discloses a native start that follows an empty snapshot`, async () => {
    const fixture = mount(renderer, undefined, [{
      type: "provider.started", providerId: "copilot", sessionId: "native-owned-session",
      executablePath: "/native/copilot", arguments: ["--headless"],
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: disclosure,
      },
    }]);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>(
        'button[aria-label="Stop"]',
      )?.disabled === false);
      expect(fixture.errors).toEqual([]);
      expect(fixture.dom.window.document.body.textContent).toContain(disclosure);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} renderer disables real submitted input after a typed occupied-native failure`, async () => {
    const fixture = mount(renderer, {
      providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
      executionDisclosure: disclosure,
    });
    try {
      const document = fixture.dom.window.document;
      await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const editor = document.querySelector<HTMLTextAreaElement>("textarea");
      if (editor) {
        editor.value = "owner draft";
        editor.dispatchEvent(new fixture.dom.window.InputEvent("input", { bubbles: true, data: "owner draft" }));
      } else {
        const paragraph = document.querySelector(".ProseMirror p");
        if (!paragraph) throw new Error("Missing actual ProseMirror paragraph.");
        paragraph.textContent = "owner draft";
        paragraph.dispatchEvent(new fixture.dom.window.InputEvent("input", { bubbles: true, data: "owner draft" }));
      }
      await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="Send"]')?.disabled === false);
      const bridge = fixture.dom.window.cmuxAgentBridge;
      if (!bridge) throw new Error("Missing actual renderer bridge.");
      bridge.receive({
        type: "provider.nativeSession", providerId: "copilot", sessionId: "native-owned-session",
        nativeSession: {
          providerId: "copilot", sessionId: "native-owned-session", status: "failed", revision: 4,
          executionDisclosure: disclosure,
        },
      });
      await waitFor(() => document.querySelector('[role="status"]')?.textContent === "Failed");
      expect(document.querySelector<HTMLButtonElement>('button[aria-label="Send"]')?.disabled).toBe(true);
      expect(document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled).toBe(false);
      document.querySelector("form")?.dispatchEvent(new fixture.dom.window.Event("submit", { bubbles: true, cancelable: true }));
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(fixture.errors).toEqual([]);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
      const stop = document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]');
      if (!stop) throw new Error("Missing actual native Stop action.");
      stop.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(document.querySelector('[role="status"]')?.textContent).toBe("Failed");
      expect(stop.disabled).toBe(false);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual(["provider.stop"]);
    } finally {
      fixture.dom.window.close();
    }
  });
}
