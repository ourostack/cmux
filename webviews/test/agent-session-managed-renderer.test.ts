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
  let completeCommand: (() => void) | null = null;
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
        if (request.method === "terminal.runCommand") {
          await new Promise<void>((resolve) => { completeCommand = resolve; });
          return { ok: true, value: {} };
        }
        throw new Error(`Unexpected native operation: ${request.method}`);
      },
    } } },
  });
  const source = bundles.get(renderer);
  if (!source) throw new Error(`Missing built ${renderer} fixture.`);
  dom.window.eval(readFileSync(new URL("../../Resources/markdown-viewer/marked.min.js", import.meta.url), "utf8"));
  dom.window.eval(source);
  return { dom, errors, messages, completeCommand: () => {
    if (!completeCommand) throw new Error("No controlled command completion is pending.");
    completeCommand();
  } };
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = performance.now() + 1000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("Actual renderer did not reach the expected DOM state.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

type ComposerSnapshot = { editorText: string; editVersion: string; render: string };
type ComposerReceipt = { leaseId: string; render: string };
type ManagedComposer = {
  capture(): ComposerSnapshot | null;
  reserve(snapshot: ComposerSnapshot, text: string): Promise<ComposerReceipt | null>;
  validate(receipt: ComposerReceipt): boolean;
  release(leaseId: string): void;
};

function composer(fixture: ReturnType<typeof mount>): ManagedComposer {
  const bridge = fixture.dom.window.cmuxAgentBridge as typeof fixture.dom.window.cmuxAgentBridge & {
    managedComposer?: ManagedComposer;
  };
  expect(typeof bridge?.managedComposer?.capture).toBe("function");
  if (!bridge?.managedComposer) throw new Error("Missing actual composer reservation path.");
  return bridge.managedComposer;
}

function paintedFixture(renderer: RendererKind) {
  const fixture = mount(renderer, {
    providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
    executionDisclosure: disclosure,
  });
  // JSDOM has no layout engine or OS focus; only those environmental facts are controlled.
  fixture.dom.window.document.hasFocus = () => true;
  fixture.dom.window.HTMLElement.prototype.getBoundingClientRect = () =>
    new fixture.dom.window.DOMRect(10, 10, 300, 100);
  fixture.dom.window.HTMLElement.prototype.getClientRects = function () {
    return [this.getBoundingClientRect()] as unknown as DOMRectList;
  };
  fixture.dom.window.Range.prototype.getBoundingClientRect = () =>
    new fixture.dom.window.DOMRect(10, 10, 1, 20);
  fixture.dom.window.Range.prototype.getClientRects = function () {
    return [this.getBoundingClientRect()] as unknown as DOMRectList;
  };
  fixture.dom.window.scrollBy = (x: number | ScrollToOptions = {}, y?: number) => {
    const left = typeof x === "number" ? x : x.left ?? 0;
    const top = typeof x === "number" ? y ?? 0 : x.top ?? 0;
    Object.defineProperties(fixture.dom.window, {
      scrollX: { value: fixture.dom.window.scrollX + left, configurable: true },
      scrollY: { value: fixture.dom.window.scrollY + top, configurable: true },
    });
    fixture.dom.window.dispatchEvent(new fixture.dom.window.Event("scroll"));
  };
  let now = 100;
  Object.defineProperty(fixture.dom.window.performance, "now", { value: () => now });
  return { ...fixture, advance: (milliseconds: number) => { now += milliseconds; } };
}

async function paintedCapture(lane: ManagedComposer): Promise<ComposerSnapshot> {
  const deadline = performance.now() + 1000;
  while (performance.now() < deadline) {
    const snapshot = lane.capture();
    if (snapshot) return snapshot;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("Missing painted capture.");
}

async function editActualComposer(fixture: ReturnType<typeof mount>, text: string): Promise<void> {
  await paintedCapture(composer(fixture));
  const document = fixture.dom.window.document;
  const editor = document.querySelector<HTMLTextAreaElement>("textarea");
  if (editor) {
    editor.value = text;
    editor.dispatchEvent(new fixture.dom.window.InputEvent("input", { bubbles: true, data: text }));
  } else {
    const paragraph = document.querySelector(".ProseMirror p");
    if (!paragraph) throw new Error("Missing actual ProseMirror paragraph.");
    paragraph.textContent = text;
    paragraph.dispatchEvent(new fixture.dom.window.InputEvent("input", { bubbles: true, data: text }));
  }
  await waitFor(() => {
    if (fixture.errors.length) throw new Error(`Actual editor failed: ${fixture.errors.join("; ")}`);
    return fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Send"]')?.disabled === (text.length === 0);
  });
  await new Promise((resolve) => setTimeout(resolve, 5));
}

for (const renderer of ["react", "solid"] as const) {
  test(`actual ${renderer} renderer refuses a typed-A edited-B back-to-A snapshot`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      fixture.dom.window.document.querySelector<HTMLElement>("textarea, .ProseMirror")?.focus();
      const lane = composer(fixture);
      await editActualComposer(fixture, "A");
      const snapshot = await paintedCapture(lane);
      await editActualComposer(fixture, "B");
      await editActualComposer(fixture, "A");
      const current = await paintedCapture(lane);
      expect(current.editorText).toBe("A");
      expect(current.editVersion).not.toBe(snapshot.editVersion);
      expect(await lane.reserve(snapshot, "stale")).toBeNull();
      expect((await paintedCapture(lane)).editorText).toBe("A");
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} queued command completion cannot clear a reserved composer`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      document.querySelector<HTMLElement>("textarea, .ProseMirror")?.focus();
      const lane = composer(fixture);
      await editActualComposer(fixture, "!echo controlled");
      document.querySelector("form")?.dispatchEvent(new fixture.dom.window.Event("submit", { bubbles: true, cancelable: true }));
      await waitFor(() => fixture.messages.includes("terminal.runCommand"));
      const receipt = await lane.reserve(await paintedCapture(lane), "!echo controlled");
      if (!receipt) throw new Error("Missing same-text insertion receipt.");
      fixture.completeCommand();
      await new Promise((resolve) => setTimeout(resolve, 5));
      fixture.advance(150);
      expect(lane.validate(receipt)).toBe(true);
      lane.release(receipt.leaseId);
      expect((await paintedCapture(lane)).editorText).toBe("!echo controlled");
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list"))
        .toEqual(["terminal.runCommand"]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} reservation catches outside DOM ABA and cannot be revived with an old receipt`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      document.querySelector<HTMLElement>("textarea, .ProseMirror")?.focus();
      const lane = composer(fixture);
      const receipt = await lane.reserve(await paintedCapture(lane), "reserved input");
      if (!receipt) throw new Error("Missing insertion receipt.");
      const status = document.querySelector('[role="status"]');
      if (!status) throw new Error("Missing actual outside status.");
      const original = status.textContent;
      status.textContent = "temporary outside change";
      status.textContent = original;
      fixture.advance(150);
      expect(lane.validate(receipt)).toBe(false);
      const fresh = await lane.reserve(await paintedCapture(lane), "new reserved input");
      if (!fresh) throw new Error("Missing renewed reservation.");
      expect(lane.validate(receipt)).toBe(false);
      lane.release(receipt.leaseId);
      fixture.advance(150);
      expect(lane.validate(fresh)).toBe(true);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} capture requires a new paint after hidden-panel ABA`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      document.querySelector<HTMLElement>("textarea, .ProseMirror")?.focus();
      const lane = composer(fixture);
      await paintedCapture(lane);
      document.body.hidden = true;
      expect(lane.capture()).toBeNull();
      document.body.hidden = false;
      expect(lane.capture()).toBeNull();
      expect((await paintedCapture(lane)).editorText).toBe("");
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} reservation inserts literal text without focus and enforces processing separation and expiry`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      const editor = document.querySelector<HTMLElement>("textarea, .ProseMirror");
      if (!editor) throw new Error("Missing actual editor.");
      editor.focus();
      await new Promise((resolve) => fixture.dom.window.requestAnimationFrame(resolve));
      const lane = composer(fixture);
      const snapshot = await paintedCapture(lane);
      expect(snapshot.editorText).toBe("");
      let focusCalls = 0;
      editor.focus = () => { focusCalls += 1; };
      const receipt = await lane.reserve(snapshot, "<script>literal</script>\n@owner $token");
      expect(receipt).not.toBeNull();
      expect(editor instanceof fixture.dom.window.HTMLTextAreaElement ? editor.value
        : Array.from(editor.querySelectorAll("p"), (paragraph) => paragraph.textContent).join("\n"))
        .toBe("<script>literal</script>\n@owner $token");
      expect(editor.querySelector("script")).toBeNull();
      expect(focusCalls).toBe(0);
      if (!receipt) throw new Error("Missing insertion receipt.");
      expect(lane.validate(receipt)).toBe(false);
      fixture.advance(149);
      expect(lane.validate(receipt)).toBe(false);
      fixture.advance(1);
      expect(lane.validate(receipt)).toBe(true);
      fixture.advance(1850);
      expect(lane.validate(receipt)).toBe(false);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} reservation refuses competing submit and synthetic edit, then revokes before native output rendering`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      const editor = document.querySelector<HTMLElement>("textarea, .ProseMirror");
      if (!editor) throw new Error("Missing actual editor.");
      editor.focus();
      await new Promise((resolve) => fixture.dom.window.requestAnimationFrame(resolve));
      const lane = composer(fixture);
      const snapshot = await paintedCapture(lane);
      const receipt = await lane.reserve(snapshot, "reserved input");
      expect(receipt).not.toBeNull();
      document.querySelector("form")?.dispatchEvent(new fixture.dom.window.Event("submit", { bubbles: true, cancelable: true }));
      editor.dispatchEvent(new fixture.dom.window.InputEvent("beforeinput", {
        bubbles: true, cancelable: true, data: "competing", inputType: "insertText",
      }));
      fixture.advance(150);
      if (!receipt) throw new Error("Missing insertion receipt.");
      expect(lane.validate(receipt)).toBe(true);
      fixture.dom.window.cmuxAgentBridge?.receive({
        type: "provider.output", providerId: "copilot", sessionId: "native-owned-session",
        stream: "stdout", text: "output revokes reservation",
      });
      expect(lane.validate(receipt)).toBe(false);
      await waitFor(() => document.body.textContent?.includes("output revokes reservation") === true);
      expect(fixture.messages.filter((method) => method !== "app.context" && method !== "provider.list")).toEqual([]);
    } finally {
      fixture.dom.window.close();
    }
  });

  test(`actual ${renderer} capture refuses stale outside content, focus loss and detached editors`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      const editor = document.querySelector<HTMLElement>("textarea, .ProseMirror");
      if (!editor) throw new Error("Missing actual editor.");
      editor.focus();
      await new Promise((resolve) => fixture.dom.window.requestAnimationFrame(resolve));
      const lane = composer(fixture);
      const snapshot = await paintedCapture(lane);
      document.querySelector('[role="status"]')?.append("changed actual viewport");
      expect(await lane.reserve(snapshot, "must not insert")).toBeNull();
      expect(editor instanceof fixture.dom.window.HTMLTextAreaElement ? editor.value : editor.textContent).toBe("");
      editor.blur();
      expect(lane.capture()).toBeNull();
      editor.remove();
      expect(lane.capture()).toBeNull();
    } finally {
      fixture.dom.window.close();
    }
  });

  for (const reverted of [false, true]) {
  test(`actual ${renderer} reservation rejects ${reverted ? "outside ABA" : "outside changes"} during insertion paint`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      const editor = document.querySelector<HTMLElement>("textarea, .ProseMirror");
      if (!editor) throw new Error("Missing actual editor.");
      editor.focus();
      const lane = composer(fixture);
      const snapshot = await paintedCapture(lane);
      const pending = lane.reserve(snapshot, "pending paint");
      const status = document.querySelector('[role="status"]');
      if (!status) throw new Error("Missing actual outside status.");
      const original = status.textContent;
      status.textContent = "changed while waiting for paint";
      if (reverted) status.textContent = original;
      expect(await pending).toBeNull();
    } finally {
      fixture.dom.window.close();
    }
  });
  }

  test(`actual ${renderer} reservation revokes on direct editor DOM changes before its model catches up`, async () => {
    const fixture = paintedFixture(renderer);
    try {
      await waitFor(() => fixture.dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Stop"]')?.disabled === false);
      const document = fixture.dom.window.document;
      const editor = document.querySelector<HTMLElement>("textarea, .ProseMirror");
      if (!editor) throw new Error("Missing actual editor.");
      editor.focus();
      const lane = composer(fixture);
      const receipt = await lane.reserve(await paintedCapture(lane), "reserved input");
      if (!receipt) throw new Error("Missing insertion receipt.");
      fixture.advance(150);
      expect(lane.validate(receipt)).toBe(true);
      if (editor instanceof fixture.dom.window.HTMLTextAreaElement) {
        editor.value = "changed DOM";
      } else {
        const paragraph = editor.querySelector("p");
        if (!paragraph) throw new Error("Missing actual editor paragraph.");
        paragraph.textContent = "changed DOM";
      }
      expect(lane.validate(receipt)).toBe(false);
    } finally {
      fixture.dom.window.close();
    }
  });

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
