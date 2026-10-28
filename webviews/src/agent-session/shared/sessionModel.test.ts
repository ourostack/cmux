import { expect, test } from "bun:test";
import { makeClientId } from "./ids";
import {
  autoStartProvider,
  autoStartStateEquals,
  canStartProvider,
  canSelectProvider,
  canStopProvider,
  formatTemplate,
  initialState,
  managedExecutionDisclosure,
  messageForError,
  pickAutoStartState,
  reduceSession,
  sendInput,
  shouldAutoStartProvider,
  statusLabel,
  type Action,
} from "./sessionModel";
import type { AgentEvent, AppContext, ProviderInfo } from "./types";

const theme = {
  isDark: true,
  pageBackground: "transparent",
  surfaceBackground: "rgba(0, 0, 0, 0.3)",
  surfaceElevatedBackground: "rgba(0, 0, 0, 0.4)",
  inputBackground: "rgba(0, 0, 0, 0.2)",
  border: "rgba(255, 255, 255, 0.1)",
  borderStrong: "rgba(255, 255, 255, 0.2)",
  text: "rgba(255, 255, 255, 1)",
  mutedText: "rgba(255, 255, 255, 0.6)",
  softText: "rgba(255, 255, 255, 0.8)",
  accent: "rgba(138, 180, 248, 1)",
  accentSoft: "rgba(138, 180, 248, 0.2)",
  danger: "rgba(255, 141, 126, 1)",
  shadow: "rgba(0, 0, 0, 0.2)",
};

const context: AppContext = {
  panelId: "panel-1",
  workspaceId: "workspace-1",
  renderer: "react",
  initialProviderId: "codex",
  copy: {
    start: "Start",
    stop: "Stop",
    send: "Send",
    provider: "Provider",
    rateLimits: "Rate limits",
    rateLimitUsageRemaining: "Usage remaining",
    rateLimitPrimary: "Primary",
    rateLimitSecondary: "Secondary",
    rateLimitWeekly: "Weekly",
    rateLimitMonthly: "Monthly",
    rateLimitDaysFormat: "%@d",
    rateLimitHoursFormat: "%@h",
    rateLimitMinutesFormat: "%@m",
    rateLimitResets: "resets",
    voiceInput: "Voice input",
    promptPlaceholder: "Ask anything",
    attachFile: "Attach file",
    addFilesAndMore: "Add files and more",
    addPhotosAndFiles: "Add photos & files",
    removeAttachment: "Remove attachment",
    copyOutput: "Copy output",
    copyAssistantMessage: "Copy",
    copiedAssistantMessage: "Copied",
    copyUserMessage: "Copy message",
    copiedUserMessage: "Copied",
    shellLabel: "Shell",
    copyShellContents: "Copy shell contents",
    copiedShellContents: "Copied shell contents",
    collapseShell: "Collapse shell",
    shellSuccess: "Success",
    showMore: "Show more",
    showLess: "Show less",
    browseWeb: "Browse web",
    autoContext: "Context",
    includeIdeContext: "Include IDE context",
    ideContext: "IDE context",
    tools: "Tools",
    changePermissions: "Change permissions",
    permissionsDefault: "Default permissions",
    permissionsFullAccess: "Full access",
    permissionsAutoReview: "Auto-review",
    permissionsCustom: "Custom (config.toml)",
    reasoningEffortHigh: "High",
    mentionMenuTitle: "Mention",
    mentionCurrentWorkspace: "Current workspace",
    skillMenuTitle: "Skills",
    composerNoResults: "No results",
    planMode: "Plan mode",
    planSuggestionAction: "Use plan mode",
    planSuggestionDismiss: "Dismiss suggestion",
    planSuggestionShortcut: "Shift + Tab",
    planSuggestionTitle: "Create a plan",
    skillPlan: "Plan",
    skillCodeReview: "Code review",
    skillResearch: "Research",
    loadingStatus: "Loading",
    idleStatus: "Idle",
    startingStatus: "Starting",
    runningStatus: "Running",
    stoppingStatus: "Stopping",
    failedStatus: "Failed",
    rendererReadyFormat: "%@ ready",
    stopped: "Stopped",
    sentCharsFormat: "Sent %d chars",
    providerStarted: "Provider started",
    providerExitedFormat: "Provider exited %d",
    requestFailed: "Native bridge request failed.",
  },
  theme,
};

const providers: ProviderInfo[] = [
  {
    id: "codex",
    displayName: "Codex",
    executableName: "codex",
    transportKind: "stdio-jsonrpc",
    arguments: ["app-server", "--listen", "stdio://"],
    autoStart: true,
  },
  {
    id: "claude",
    displayName: "Claude Code",
    executableName: "claude",
    transportKind: "stdio-jsonl",
    arguments: ["-p"],
    autoStart: false,
  },
];

test("provider started event records running session", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const state = reduceSession(starting, {
    type: "event",
    event: {
      type: "provider.started",
      providerId: "codex",
      sessionId: "session-1",
      executablePath: "/usr/local/bin/codex",
      arguments: ["app-server", "--listen", "stdio://"],
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.text).toBe("Provider started");
});

test("rate limit row event updates context", () => {
  const initial = reduceSession(initialState("react"), { type: "context", context });
  const state = reduceSession(initial, {
    type: "event",
    event: {
      type: "app.rateLimitRows",
      rateLimitRows: [
        {
          role: "primary",
          remainingPercent: 42,
          resetsAt: 1_850_000_000,
        },
      ],
    },
  });

  expect(state.context?.rateLimitRows).toEqual([
    {
      role: "primary",
      remainingPercent: 42,
      resetsAt: 1_850_000_000,
    },
  ]);
});

test("provider output is appended without changing running session", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-1",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.level).toBe("stdout");
  expect(state.transcript.at(-1)).toMatchObject({
    isComplete: false,
    role: "assistant",
    sessionId: "session-1",
    sentAtMs: expect.any(Number),
    text: "{\"type\":\"assistant\"}",
  });
});

test("provider output log entries are byte bounded", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "a".repeat(1024 * 1024),
    },
  });

  const logText = state.log.at(-1)?.text ?? "";
  expect(logText.length).toBeLessThanOrEqual(8 * 1024);
  expect(logText.startsWith("[earlier log output truncated]\n")).toBe(true);
});

test("provider stdout deltas append to the current assistant transcript turn", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const first = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "hello",
    },
  });
  const second = reduceSession(first, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: " world",
    },
  });

  expect(second.transcript).toHaveLength(1);
  expect(second.transcript[0]).toMatchObject({
    isComplete: false,
    role: "assistant",
    sentAtMs: first.transcript[0]?.sentAtMs,
    text: "hello world",
  });
});

test("provider turn completion marks the active assistant transcript complete", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const withOutput = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "done",
    },
  });
  const completed = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.turnComplete",
      providerId: "codex",
      sessionId: "session-1",
    },
  });

  expect(completed.status).toBe("running");
  expect(completed.runningSessionId).toBe("session-1");
  expect(completed.transcript[0]).toMatchObject({
    isComplete: true,
    role: "assistant",
    text: "done",
  });
});

test("provider exit marks assistant transcript complete", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const withOutput = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stdout",
      text: "done",
    },
  });
  const exited = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 0,
    },
  });

  expect(exited.transcript[0]).toMatchObject({
    isComplete: true,
    role: "assistant",
    text: "done",
  });
});

test("provider activity updates a single transcript turn by activity id", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const started = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      detail: "bun test",
    },
  });
  const withOutput = reduceSession(started, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      outputDelta: "ok\\n",
    },
  });
  const completed = reduceSession(withOutput, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "completed",
      action: "Ran",
      detail: "bun test",
    },
  });

  expect(completed.transcript).toHaveLength(1);
  expect(completed.transcript[0]).toMatchObject({
    role: "activity",
    text: "Ran",
    detail: "bun test",
    output: "ok\\n",
    activityKind: "command",
    activityStatus: "completed",
  });
});

test("provider activity output is retained with a bounded tail", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const started = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
    },
  });
  const first = reduceSession(started, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "inProgress",
      action: "Running",
      outputDelta: "a".repeat(70_000),
    },
  });
  const second = reduceSession(first, {
    type: "event",
    event: {
      type: "provider.activity",
      providerId: "codex",
      sessionId: "session-1",
      activityId: "item-1",
      kind: "command",
      status: "completed",
      action: "Ran",
      outputDelta: "tail",
    },
  });

  const output = second.transcript[0]?.output ?? "";
  expect(output.length).toBeLessThanOrEqual(64 * 1024);
  expect(output.startsWith("[earlier command output truncated]\n")).toBe(true);
  expect(output.endsWith("tail")).toBe(true);
});

test("sent action appends a user transcript turn", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
    input: "hello codex",
  };
  const state = reduceSession(running, {
    type: "sent",
    sessionId: "session-1",
    sentAtMs: 1_850_000_000_000,
    text: "hello codex",
    submittedInput: "hello codex",
    submittedInputVersion: running.inputVersion,
  });

  expect(state.input).toBe("");
  expect(state.transcript.at(-1)).toMatchObject({
    role: "user",
    sentAtMs: 1_850_000_000_000,
    text: "hello codex",
  });
});

test("sent action keeps displayed attachments separate from provider prompt text", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
    input: "describe this",
  };
  const attachment = {
    id: "attachment-1",
    kind: "image" as const,
    label: "moon.jpeg",
    path: "/tmp/moon.jpeg",
    dataUrl: "data:image/jpeg;base64,abc",
  };
  const state = reduceSession(running, {
    type: "sent",
    attachments: [attachment],
    displayText: "describe this",
    sessionId: "session-1",
    text: "[moon.jpeg](/tmp/moon.jpeg)\n\ndescribe this",
    submittedInput: "describe this",
    submittedInputVersion: running.inputVersion,
  });

  expect(state.input).toBe("");
  expect(state.log.at(-1)?.text).toBe("Sent 42 chars");
  expect(state.transcript.at(-1)).toMatchObject({
    role: "user",
    text: "describe this",
    attachments: [attachment],
  });
});

test("stderr output appends a warning notice transcript turn", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "codex",
      sessionId: "session-1",
      stream: "stderr",
      text: "warning text",
    },
  });

  expect(state.transcript.at(-1)).toMatchObject({
    role: "notice",
    tone: "warning",
    text: "warning text",
  });
});

test("provider output for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-x",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state).toBe(running);
});

test("unknown provider events are ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: { type: "provider.unknown", sessionId: "session-1" } as never,
  });

  expect(state).toBe(running);
});

test("accepted start reply tracks session before provider started event", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const accepted = reduceSession(starting, { type: "startAccepted", sessionId: "session-1" });

  expect(accepted.status).toBe("starting");
  expect(accepted.runningSessionId).toBe("session-1");
  expect(canStopProvider(accepted)).toBe(true);

  const failed = reduceSession(accepted, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "opencode",
      sessionId: "session-1",
      status: 1,
    },
  });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBeUndefined();
});

test("provider exit during pending start is applied before start reply", () => {
  const starting = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "starting" },
  );
  const failed = reduceSession(starting, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-early-exit",
      status: 1,
    },
  });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBeUndefined();
  expect(failed.log.at(-1)?.text).toBe("Provider exited 1");

  const staleAccepted = reduceSession(failed, { type: "startAccepted", sessionId: "session-early-exit" });
  expect(staleAccepted.status).toBe("failed");
  expect(staleAccepted.runningSessionId).toBeUndefined();
});

test("stale exit from a previous seen session is ignored during pending start", () => {
  const loaded = reduceSession(initialState("react"), { type: "context", context });
  const firstStart = reduceSession(loaded, { type: "starting" });
  const accepted = reduceSession(firstStart, { type: "startAccepted", sessionId: "session-1" });
  const exited = reduceSession(accepted, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 0,
    },
  });
  const restarting = reduceSession(exited, { type: "starting" });
  const state = reduceSession(restarting, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 1,
    },
  });

  expect(state).toBe(restarting);
  expect(state.status).toBe("starting");
});

test("provider exit for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "claude",
      sessionId: "session-x",
      status: 143,
    },
  });

  expect(state).toBe(running);
});

test("auto start is enabled for idle auto-start providers after context and providers load", () => {
  const stateWithContext = reduceSession(initialState("react"), { type: "context", context });
  const state = reduceSession(stateWithContext, { type: "providers", providers });

  expect(shouldAutoStartProvider(state)).toBe(true);
});

test("restored Copilot context cannot start through the generic browser path", () => {
  for (const renderer of ["react", "solid"] as const) {
    const restored = reduceSession(initialState(renderer), {
      type: "context",
      context: { ...context, renderer, initialProviderId: "copilot" },
    });
    const state = reduceSession(restored, {
      type: "providers",
      providers: [{
        id: "copilot",
        displayName: "GitHub Copilot",
        executableName: "copilot",
        transportKind: "managed-stdio-jsonrpc",
        arguments: [],
        autoStart: true,
      }],
    });
    expect(canStartProvider(state)).toBe(false);
    expect(shouldAutoStartProvider(state)).toBe(false);
    expect(state.runningSessionId).toBeUndefined();
  }
});

test("native context recovers managed lifecycle state after pre-navigation events were lost", () => {
  for (const renderer of ["react", "solid"] as const) {
    for (const [status, revision] of [["starting", 1], ["running", 2], ["stopping", 3], ["failed", 4]] as const) {
      const drafted = reduceSession(initialState(renderer), {
        type: "setInput", input: "owner draft", inputVersion: "owner-edit-1",
      });
      const state = reduceSession(drafted, {
        type: "context",
        context: {
          ...context,
          renderer,
          initialProviderId: "copilot",
          nativeSession: {
            providerId: "copilot",
            sessionId: "native-owned-session",
            status,
            revision,
            executionDisclosure: "Native-owned foreground OS-account execution; no sandbox.",
          },
        },
      });
      expect(state.status).toBe(status);
      expect(state.runningSessionId).toBe("native-owned-session");
      expect(state.selectedProviderId).toBe("copilot");
      expect(canStartProvider(state)).toBe(false);
      expect(canSelectProvider(state)).toBe(false);
      expect(state.input).toBe("owner draft");
      expect(state.inputVersion).toBe("owner-edit-1");
    }
  }
});

test("native events received while initial context is in flight are replayed after its snapshot", () => {
  const earlyStarted = reduceSession(initialState("react"), {
    type: "event",
    event: {
      type: "provider.started", providerId: "copilot", sessionId: "native-owned-session",
      executablePath: "/native/copilot", arguments: ["--headless"],
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  const earlyOutput = reduceSession(earlyStarted, {
    type: "event",
    event: {
      type: "provider.output", providerId: "copilot", sessionId: "native-owned-session",
      stream: "stdout", text: "Output after the captured native snapshot",
    },
  });
  const state = reduceSession(earlyOutput, {
    type: "context",
    context: {
      ...context, initialProviderId: "copilot",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "starting", revision: 1,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(state.transcript.at(-1)?.text).toBe("Output after the captured native snapshot");
});

test("a native exit during the initial context request cannot resurrect its captured session", () => {
  const exited = reduceSession(initialState("solid"), {
    type: "event",
    event: {
      type: "provider.exit", providerId: "copilot", sessionId: "native-owned-session", status: 1,
    },
  });
  const state = reduceSession(exited, {
    type: "context",
    context: {
      ...context, renderer: "solid", initialProviderId: "copilot",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBeUndefined();
  expect(state.transcript.at(-1)?.text).toBe("Provider exited 1");
});

test("a native start after an empty context snapshot is still projected without a browser start request", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context", context: { ...context, initialProviderId: "copilot" },
  });
  const state = reduceSession(loaded, {
    type: "event",
    event: {
      type: "provider.started", providerId: "copilot", sessionId: "native-owned-session",
      executablePath: "/native/copilot", arguments: ["--headless"],
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(canStartProvider(state)).toBe(false);
  expect(state.context?.nativeSession?.executionDisclosure).toBe("OS-account commands, no sandbox.");
});

test("native lifecycle failure supersedes a running snapshot without clearing its occupied owner", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context, initialProviderId: "copilot",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  const state = reduceSession(loaded, {
    type: "event",
    event: {
      type: "provider.nativeSession", providerId: "copilot", sessionId: "native-owned-session",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "failed", revision: 4,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(canStopProvider(state)).toBe(true);
});

test("Stop preserves an authoritative failed occupied native owner instead of inventing a closing transition", () => {
  const failed = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context, initialProviderId: "copilot",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "failed", revision: 4,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  const state = reduceSession(failed, { type: "stopping", sessionId: "native-owned-session" });
  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(canStopProvider(state)).toBe(true);
});

test("equal failed native lifecycle repairs optimistic local Stop without replacing or releasing its owner", () => {
  const nativeSession = {
    providerId: "copilot", sessionId: "native-owned-session", status: "failed", revision: 4,
    executionDisclosure: "OS-account commands, no sandbox.",
  } as const;
  const failed = reduceSession(initialState("solid"), {
    type: "context", context: { ...context, renderer: "solid", initialProviderId: "copilot", nativeSession },
  });
  const optimistic = { ...failed, status: "stopping" as const, requestedStopSessionId: "native-owned-session" };
  const state = reduceSession(optimistic, {
    type: "event",
    event: {
      type: "provider.nativeSession", providerId: "copilot", sessionId: "native-owned-session", nativeSession,
    },
  });
  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(state.context?.nativeSession).toBe(nativeSession);
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(canStopProvider(state)).toBe(true);
});

test("an older native started event cannot revive a failed occupied snapshot", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context, initialProviderId: "copilot",
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "failed", revision: 4,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  const state = reduceSession(loaded, {
    type: "event",
    event: {
      type: "provider.started", providerId: "copilot", sessionId: "native-owned-session",
      executablePath: "/native/copilot", arguments: ["--headless"],
      nativeSession: {
        providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
        executionDisclosure: "OS-account commands, no sandbox.",
      },
    },
  });
  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("native-owned-session");
  expect(canStopProvider(state)).toBe(true);
});

test("initial event overflow stays bounded and holds input while keeping native stop available", () => {
  for (const texts of [Array<string>(65).fill("delta"), ["x".repeat(256 * 1024 + 1)]]) {
    let state = initialState("react");
    for (const text of texts) {
      state = reduceSession(state, {
        type: "event",
        event: {
          type: "provider.output", providerId: "copilot", sessionId: "native-owned-session", stream: "stdout", text,
        },
      });
    }
    state = reduceSession(state, {
      type: "context",
      context: {
        ...context, initialProviderId: "copilot",
        nativeSession: {
          providerId: "copilot", sessionId: "native-owned-session", status: "running", revision: 2,
          executionDisclosure: "OS-account commands, no sandbox.",
        },
      },
    });
    expect(state.status).toBe("failed");
    expect(state.runningSessionId).toBe("native-owned-session");
    expect(canStopProvider(state)).toBe(true);
    expect(canStartProvider(state)).toBe(false);
    expect(state.bootstrapError).toBeTruthy();
    expect(state.bootstrapEvents.length).toBeLessThanOrEqual(64);
  }
});

test("auto start is disabled after a provider has already been attempted", () => {
  const state = reduceSession(
    reduceSession(reduceSession(initialState("react"), { type: "context", context }), {
      type: "providers",
      providers,
    }),
    { type: "autoStartAttempted", providerId: "codex" },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
});

test("auto start attempts are remembered per provider switch", () => {
  const loaded = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "providers", providers },
  );
  const attemptedCodex = reduceSession(loaded, { type: "autoStartAttempted", providerId: "codex" });
  const selectedClaude = reduceSession(attemptedCodex, { type: "selectProvider", providerId: "claude" });
  const selectedCodexAgain = reduceSession(selectedClaude, { type: "selectProvider", providerId: "codex" });

  expect(shouldAutoStartProvider(selectedCodexAgain)).toBe(false);
});

test("auto start sends provider start from an explicit snapshot", async () => {
  const loaded = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "providers", providers },
  );
  const actions: Action[] = [];
  const messages: Array<{ method: string; params: Record<string, unknown> }> = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message as { method: string; params: Record<string, unknown> });
            return { ok: true, value: { sessionId: "session-auto" } };
          },
        },
      },
    },
  };

  try {
    await autoStartProvider(loaded, (action) => actions.push(action));
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(actions.map((action) => action.type)).toEqual(["autoStartAttempted", "starting", "startAccepted"]);
  expect(actions[0]).toEqual({ type: "autoStartAttempted", providerId: "codex" });
  expect(messages[0]?.method).toBe("provider.start");
  expect(messages[0]?.params.providerId).toBe("codex");
});

test("sent input only clears the submitted value", () => {
  const loaded = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const typed = reduceSession(loaded, { type: "setInput", input: "new draft" });
  const state = reduceSession(typed, {
    type: "sent",
    sessionId: "session-1",
    text: "old draft",
    submittedInput: "old draft",
    submittedInputVersion: loaded.inputVersion,
  });

  expect(state.input).toBe("new draft");
  expect(state.log.at(-1)?.text).toBe("Sent 9 chars");
});

test.each(["react", "solid"] as const)(
  "send acknowledgement preserves retyped identical input in %s",
  async (renderer) => {
    let state = reduceSession(initialState(renderer), { type: "context", context: { ...context, renderer } });
    state = { ...state, status: "running", runningSessionId: "session-1" };
    state = reduceSession(state, { type: "setInput", input: "same draft" });
    let release: () => void = () => { throw new Error("native reply was not initialized"); };
    const reply = new Promise<{ ok: true; value: { sent: true } }>((resolve) => {
      release = () => resolve({ ok: true, value: { sent: true } });
    });
    const globalWithWindow = globalThis as unknown as { window?: unknown };
    const originalWindow = globalWithWindow.window;
    globalWithWindow.window = {
      webkit: { messageHandlers: { agentSession: { postMessage: () => reply } } },
    };
    try {
      const sending = sendInput(state, (action) => {
        state = reduceSession(state, action);
      });
      state = reduceSession(state, { type: "setInput", input: "" });
      state = reduceSession(state, { type: "setInput", input: "same draft" });
      release();
      expect(await sending).toBe(true);
      expect(state.input).toBe("same draft");
    } finally {
      if (originalWindow === undefined) {
        delete globalWithWindow.window;
      } else {
        globalWithWindow.window = originalWindow;
      }
    }
  },
);

test.each([false, true])(
  "queued React editor resync clears only its own edit (newer edits: %s)",
  async (newerEdits) => {
    const rendered = {
      ...reduceSession(initialState("react"), { type: "context", context }),
      status: "running" as const,
      runningSessionId: "session-1",
    };
    const inputVersion = makeClientId();
    const actions: Action[] = [{
      type: "setInput", input: "editor is ahead", inputVersion,
    }];
    let release: () => void = () => { throw new Error("native reply was not initialized"); };
    const reply = new Promise<{ ok: true; value: { sent: true } }>((resolve) => {
      release = () => resolve({ ok: true, value: { sent: true } });
    });
    const globalWithWindow = globalThis as unknown as { window?: unknown };
    const originalWindow = globalWithWindow.window;
    globalWithWindow.window = {
      webkit: { messageHandlers: { agentSession: { postMessage: () => reply } } },
    };
    try {
      const sending = sendInput(rendered, (action) => actions.push(action), {
        text: "editor is ahead", clearInput: "editor is ahead", clearInputVersion: inputVersion,
      });
      if (newerEdits) {
        actions.push({ type: "setInput", input: "", inputVersion: makeClientId() });
        actions.push({ type: "setInput", input: "editor is ahead", inputVersion: makeClientId() });
      }
      release();
      expect(await sending).toBe(true);
      const state = actions.reduce<ReturnType<typeof initialState>>(reduceSession, rendered);
      expect(state.input).toBe(newerEdits ? "editor is ahead" : "");
    } finally {
      if (originalWindow === undefined) {
        delete globalWithWindow.window;
      } else {
        globalWithWindow.window = originalWindow;
      }
    }
  },
);

test("late sent replies do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
    input: "draft",
  };
  const state = reduceSession(stopping, {
    type: "sent",
    sessionId: "session-1",
    text: "draft",
    submittedInput: "draft",
    submittedInputVersion: stopping.inputVersion,
  });

  expect(state).toBe(stopping);
});

test("send waits until provider is running after start is accepted", async () => {
  const loaded = reduceSession(initialState("react"), { type: "context", context });
  const starting = {
    ...reduceSession(loaded, { type: "setInput", input: "hello" }),
    status: "starting" as const,
    runningSessionId: "session-1",
  };
  const actions: Action[] = [];
  const messages: unknown[] = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message);
            return { ok: false, error: { userMessage: "Provider not ready" } };
          },
        },
      },
    },
  };

  try {
    await sendInput(starting, (action) => actions.push(action));
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages).toHaveLength(0);
  expect(actions).toHaveLength(0);
});

test("send includes selected permission mode", async () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    input: "needs access",
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const messages: Array<{ method: string; params: Record<string, unknown> }> = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message as { method: string; params: Record<string, unknown> });
            return { ok: true, value: { sent: true } };
          },
        },
      },
    },
  };

  try {
    await sendInput(running, () => {}, { permissionMode: "full-access" });
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages[0]?.method).toBe("provider.writeLine");
  expect(messages[0]?.params.permissionMode).toBe("full-access");
});

test("stop preserves running session until provider exit arrives", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const stopping = reduceSession(running, { type: "stopping", sessionId: "session-1" });

  expect(stopping.status).toBe("stopping");
  expect(stopping.runningSessionId).toBe("session-1");
  expect(stopping.requestedStopSessionId).toBe("session-1");
  expect(statusLabel(stopping)).toBe("Stopping");
});

test("requested stop exits return to idle even with signal status", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 15,
    },
  });

  expect(state.status).toBe("idle");
  expect(state.runningSessionId).toBeUndefined();
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(state.log.at(-1)?.text).toBe("Stopped");
});

test("late stop failures do not overwrite a clean stop exit", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const stopped = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "codex",
      sessionId: "session-1",
      status: 15,
    },
  });
  const state = reduceSession(stopped, {
    type: "stopFailed",
    sessionId: "session-1",
    message: "The agent session is no longer available.",
  });

  expect(state.status).toBe("idle");
  expect(state.runningSessionId).toBeUndefined();
  expect(state.log.at(-1)?.text).toBe("Stopped");
});

test("late send failures do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "sendFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state).toBe(stopping);
});

test("session-scoped failures do not overwrite a requested stop", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "failedForSession",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state).toBe(stopping);
});

test("bridge request errors use copy from session state", () => {
  const state = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context,
      copy: { ...context.copy, requestFailed: "Localized bridge failure." },
    },
  });

  expect(messageForError(new Error("Native bridge request failed."), state)).toBe("Localized bridge failure.");
});

test("send failures for the active running session keep stop available", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "sendFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("session-1");
  expect(canStopProvider(state)).toBe(true);
});

test("transient provider busy send failures keep the session running", async () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    input: "second turn",
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const actions: Action[] = [];
  const messages: unknown[] = [];
  const globalWithWindow = globalThis as unknown as { window?: unknown };
  const originalWindow = globalWithWindow.window;
  globalWithWindow.window = {
    webkit: {
      messageHandlers: {
        agentSession: {
          async postMessage(message: unknown) {
            messages.push(message);
            return {
              ok: false,
              error: {
                code: "providerNotReady",
                userMessage: "The provider is not ready yet.",
              },
            };
          },
        },
      },
    },
  };

  try {
    const sent = await sendInput(running, (action) => actions.push(action));
    expect(sent).toBe(false);
  } finally {
    if (originalWindow === undefined) {
      delete globalWithWindow.window;
    } else {
      globalWithWindow.window = originalWindow;
    }
  }

  expect(messages).toHaveLength(1);
  expect(actions).toHaveLength(0);
});

test("stop failures for an active session keep stop available", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "stopFailed",
    sessionId: "session-1",
    message: "Native bridge request failed.",
  });

  expect(state.status).toBe("failed");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.requestedStopSessionId).toBeUndefined();
  expect(canStopProvider(state)).toBe(true);
});

test("provider started during a requested stop is ignored", () => {
  const stopping = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "stopping" as const,
    runningSessionId: "session-1",
    requestedStopSessionId: "session-1",
  };
  const state = reduceSession(stopping, {
    type: "event",
    event: {
      type: "provider.started",
      providerId: "codex",
      sessionId: "session-1",
      executablePath: "/usr/local/bin/codex",
      arguments: ["app-server", "--listen", "stdio://"],
    },
  });

  expect(state).toBe(stopping);
});

test("format templates honor positional specifiers", () => {
  expect(formatTemplate("%2$@ %1$d", [7, "files"])).toBe("files 7");
});

test("failed calls with an active session keep stop available", () => {
  const running = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const failed = reduceSession(running, { type: "failed", message: "Native bridge request failed." });

  expect(failed.status).toBe("failed");
  expect(failed.runningSessionId).toBe("session-1");
  expect(canStopProvider(failed)).toBe(true);
});

test("claude does not auto start", () => {
  const claudeContext = { ...context, initialProviderId: "claude" as const };
  const state = reduceSession(
    reduceSession(initialState("react"), { type: "context", context: claudeContext }),
    { type: "providers", providers },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
});

test("provider selection is blocked while a failed session is still active", () => {
  const failedWithActiveSession = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "failed" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(failedWithActiveSession, { type: "selectProvider", providerId: "claude" });

  expect(canSelectProvider(failedWithActiveSession)).toBe(false);
  expect(state.selectedProviderId).toBe("codex");
});

test("provider selection is allowed after a failed start without an active session", () => {
  const failedWithoutSession = {
    ...reduceSession(initialState("react"), { type: "context", context }),
    status: "failed" as const,
  };
  const state = reduceSession(failedWithoutSession, { type: "selectProvider", providerId: "claude" });

  expect(canSelectProvider(failedWithoutSession)).toBe(true);
  expect(state.selectedProviderId).toBe("claude");
});

test("client ids do not require crypto.randomUUID", () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  Object.defineProperty(globalThis, "crypto", {
    configurable: true,
    value: {
      getRandomValues(bytes: Uint8Array) {
        bytes.fill(7);
        return bytes;
      },
    },
  });

  try {
    expect(makeClientId()).toMatch(/^[0-9a-f-]{36}$/);
    const loaded = reduceSession(initialState("react"), { type: "context", context });
    expect(loaded.log[0]?.id).toMatch(/^[0-9a-f-]{36}$/);
  } finally {
    if (descriptor) {
      Object.defineProperty(globalThis, "crypto", descriptor);
    } else {
      delete (globalThis as { crypto?: unknown }).crypto;
    }
  }
});

const nativeCodexIntent = {
  providerId: "codex",
  status: "starting",
  executionDisclosure: "Native-owned foreground OS-account execution; no sandbox.",
} as const;

const nativeCodexSession = {
  providerId: "codex",
  sessionId: "native-codex-session",
  status: "running",
  revision: 2,
  executionDisclosure: "Native-owned foreground OS-account execution; no sandbox.",
} as const;

test("managed Codex intent blocks manual start and selection before native metadata exists", () => {
  for (const renderer of ["react", "solid"] as const) {
    for (const intentStatus of ["starting", "unavailable"] as const) {
      const loaded = reduceSession(initialState(renderer), {
        type: "context",
        context: {
          ...context, renderer, nativeManagedIntent: { ...nativeCodexIntent, status: intentStatus },
        },
      });
      const state = reduceSession(loaded, { type: "providers", providers });
      expect(state.status).toBe(intentStatus === "starting" ? "starting" : "failed");
      expect(state.runningSessionId).toBeUndefined();
      expect(state.selectedProviderId).toBe("codex");
      expect(canStartProvider(state)).toBe(false);
      expect(canSelectProvider(state)).toBe(false);
      expect(shouldAutoStartProvider(state)).toBe(false);
      expect(state.context?.nativeManagedIntent?.executionDisclosure).toBe(
        "Native-owned foreground OS-account execution; no sandbox.",
      );
      if (intentStatus === "unavailable") expect(state.bootstrapError).toBeTruthy();
    }
  }
});

test("managed Codex native snapshots recover every lifecycle revision for both renderers", () => {
  for (const renderer of ["react", "solid"] as const) {
    for (const [status, revision] of [["starting", 1], ["running", 2], ["stopping", 3], ["failed", 4]] as const) {
      const draft = reduceSession(initialState(renderer), {
        type: "setInput", input: "preserved native owner draft", inputVersion: "native-owner-edit",
      });
      const state = reduceSession(draft, {
        type: "context",
        context: {
          ...context, renderer, nativeManagedIntent: nativeCodexIntent,
          nativeSession: { ...nativeCodexSession, status, revision },
        },
      });
      expect(state.status).toBe(status);
      expect(state.runningSessionId).toBe("native-codex-session");
      expect(state.selectedProviderId).toBe("codex");
      expect(state.input).toBe("preserved native owner draft");
      expect(state.inputVersion).toBe("native-owner-edit");
      expect(canStartProvider(state)).toBe(false);
      expect(canSelectProvider(state)).toBe(false);
    }
  }
});

test("managed Codex revocation retains occupied stop and cannot be revived by stale native events", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context",
    context: { ...context, nativeManagedIntent: nativeCodexIntent, nativeSession: nativeCodexSession },
  });
  const revoked = reduceSession(loaded, {
    type: "event",
    event: {
      type: "provider.nativeIntent", nativeIntent: { ...nativeCodexIntent, status: "unavailable" },
    },
  });
  expect(revoked.status).toBe("failed");
  expect(revoked.runningSessionId).toBe("native-codex-session");
  expect(canStopProvider(revoked)).toBe(true);
  expect(canStartProvider(revoked)).toBe(false);
  expect(canSelectProvider(revoked)).toBe(false);
  const staleEvents: AgentEvent[] = [
    { type: "provider.nativeIntent", nativeIntent: nativeCodexIntent },
    {
      type: "provider.started", providerId: "codex", sessionId: "native-codex-session",
      executablePath: "/native/cmux-managed-codex-host", arguments: ["--private-stdio"],
      nativeSession: nativeCodexSession,
    },
  ];
  for (const event of staleEvents) {
    const state = reduceSession(revoked, { type: "event", event });
    expect(state.status).toBe("failed");
    expect(state.context?.nativeManagedIntent?.status).toBe("unavailable");
    expect(state.runningSessionId).toBe("native-codex-session");
    expect(canStopProvider(state)).toBe(true);
  }
});

test("managed Codex exit never enables generic start or provider selection", () => {
  for (const exitStatus of [0, 1]) {
    const loaded = reduceSession(initialState("solid"), {
      type: "context",
      context: {
        ...context, renderer: "solid", nativeManagedIntent: nativeCodexIntent, nativeSession: nativeCodexSession,
      },
    });
    const providersLoaded = reduceSession(loaded, { type: "providers", providers });
    const exited = reduceSession(providersLoaded, {
      type: "event",
      event: { type: "provider.exit", providerId: "codex", sessionId: "native-codex-session", status: exitStatus },
    });
    expect(exited.runningSessionId).toBeUndefined();
    expect(exited.context?.nativeManagedIntent?.providerId).toBe("codex");
    expect(canStartProvider(exited)).toBe(false);
    expect(canSelectProvider(exited)).toBe(false);
    expect(shouldAutoStartProvider(exited)).toBe(false);
    const selected = reduceSession(exited, { type: "selectProvider", providerId: "claude" });
    expect(selected.selectedProviderId).toBe("codex");
  }
});

test("managed Codex context rejects foreign provider metadata instead of falling back to manual", () => {
  const state = reduceSession(initialState("react"), {
    type: "context",
    context: {
      ...context, nativeManagedIntent: nativeCodexIntent,
      nativeSession: { ...nativeCodexSession, providerId: "copilot" },
    },
  });
  expect(state.status).toBe("failed");
  expect(state.bootstrapError).toBeTruthy();
  expect(state.context?.nativeSession).toBeUndefined();
  expect(canStartProvider(state)).toBe(false);
  expect(canSelectProvider(state)).toBe(false);
  expect(state.selectedProviderId).toBe("codex");
});

test("managed Codex ignores same-id lifecycle and output events from another provider", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context",
    context: { ...context, nativeManagedIntent: nativeCodexIntent, nativeSession: nativeCodexSession },
  });
  expect(loaded.status).toBe("running");
  expect(loaded.runningSessionId).toBe("native-codex-session");
  const foreignEvents: AgentEvent[] = [
    {
      type: "provider.started", providerId: "copilot", sessionId: "native-codex-session",
      executablePath: "/native/copilot", arguments: ["--headless"],
      nativeSession: { ...nativeCodexSession, providerId: "copilot" },
    },
    {
      type: "provider.nativeSession", providerId: "copilot", sessionId: "native-codex-session",
      nativeSession: { ...nativeCodexSession, providerId: "copilot", status: "failed", revision: 4 },
    },
    {
      type: "provider.output", providerId: "copilot", sessionId: "native-codex-session",
      stream: "stdout", text: "foreign provider output",
    },
  ];
  for (const event of foreignEvents) {
    const state = reduceSession(loaded, { type: "event", event });
    expect(state).toBe(loaded);
    expect(state.transcript.some((entry) => entry.text.includes("foreign provider output"))).toBe(false);
  }
});

test("managed Codex early native events replay against intent without requesting a browser start", () => {
  const earlyStarted = reduceSession(initialState("solid"), {
    type: "event",
    event: {
      type: "provider.started", providerId: "codex", sessionId: "native-codex-session",
      executablePath: "/native/cmux-managed-codex-host", arguments: ["--private-stdio"],
      nativeSession: nativeCodexSession,
    },
  });
  const earlyOutput = reduceSession(earlyStarted, {
    type: "event",
    event: {
      type: "provider.output", providerId: "codex", sessionId: "native-codex-session",
      stream: "stdout", text: "Native Codex output after context capture",
    },
  });
  const state = reduceSession(earlyOutput, {
    type: "context", context: { ...context, renderer: "solid", nativeManagedIntent: nativeCodexIntent },
  });
  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("native-codex-session");
  expect(state.transcript.at(-1)?.text).toBe("Native Codex output after context capture");
  expect(canStartProvider(state)).toBe(false);
  expect(canSelectProvider(state)).toBe(false);
});

test("managed Codex intent cannot be removed or switched by a later context response", () => {
  const loaded = reduceSession(initialState("react"), {
    type: "context", context: { ...context, nativeManagedIntent: nativeCodexIntent },
  });
  const downgraded = reduceSession(loaded, {
    type: "context", context: { ...context, initialProviderId: "claude" },
  });
  expect(downgraded.status).toBe("failed");
  expect(downgraded.selectedProviderId).toBe("codex");
  expect(downgraded.context?.nativeManagedIntent?.providerId).toBe("codex");
  expect(canStartProvider(downgraded)).toBe(false);
  expect(canSelectProvider(downgraded)).toBe(false);
});

test("ordinary Codex keeps manual auto-start and cannot acquire managed intent from an event", () => {
  const loaded = reduceSession(
    reduceSession(initialState("react"), { type: "context", context }),
    { type: "providers", providers },
  );
  expect(canStartProvider(loaded)).toBe(true);
  expect(canSelectProvider(loaded)).toBe(true);
  expect(shouldAutoStartProvider(loaded)).toBe(true);
  const foreignIntent = reduceSession(loaded, {
    type: "event",
    event: { type: "provider.nativeIntent", nativeIntent: nativeCodexIntent },
  });
  expect(foreignIntent).toBe(loaded);
  const started = reduceSession(reduceSession(loaded, { type: "starting" }), {
    type: "event",
    event: {
      type: "provider.started", providerId: "codex", sessionId: "manual-codex-session",
      executablePath: "/configured/codex", arguments: ["app-server", "--listen", "stdio://"],
    },
  });
  expect(started.status).toBe("running");
  expect(started.runningSessionId).toBe("manual-codex-session");
  expect(started.context?.nativeSession).toBeUndefined();
  expect(started.context?.nativeManagedIntent).toBeUndefined();
});

test("revoked managed Codex stays failed after verified cleanup even when a stop was requested", () => {
  for (const requestedStop of [false, true]) {
    const loaded = reduceSession(initialState("react"), {
      type: "context",
      context: { ...context, nativeManagedIntent: nativeCodexIntent, nativeSession: nativeCodexSession },
    });
    const revoked = reduceSession(loaded, {
      type: "event",
      event: { type: "provider.nativeIntent", nativeIntent: { ...nativeCodexIntent, status: "unavailable" } },
    });
    const closing = requestedStop
      ? reduceSession(revoked, { type: "stopping", sessionId: "native-codex-session" })
      : revoked;
    const exited = reduceSession(closing, {
      type: "event",
      event: { type: "provider.exit", providerId: "codex", sessionId: "native-codex-session", status: 0 },
    });
    expect(exited.status).toBe("failed");
    expect(exited.runningSessionId).toBeUndefined();
    expect(exited.context?.nativeManagedIntent?.status).toBe("unavailable");
    expect(exited.bootstrapError).toBeTruthy();
    expect(canStopProvider(exited)).toBe(false);
    expect(canStartProvider(exited)).toBe(false);
    expect(canSelectProvider(exited)).toBe(false);
  }
});

test("early native revocation retains its hold while a later owned session identity is recovered", () => {
  const revoked = reduceSession(initialState("solid"), {
    type: "event",
    event: { type: "provider.nativeIntent", nativeIntent: { ...nativeCodexIntent, status: "unavailable" } },
  });
  const started = reduceSession(revoked, {
    type: "event",
    event: {
      type: "provider.started", providerId: "codex", sessionId: "native-codex-session",
      executablePath: "/native/cmux-managed-codex-host", arguments: ["--private-stdio"],
      nativeSession: nativeCodexSession,
    },
  });
  const loaded = reduceSession(started, {
    type: "context", context: { ...context, renderer: "solid", nativeManagedIntent: nativeCodexIntent },
  });
  expect(loaded.status).toBe("failed");
  expect(loaded.context?.nativeManagedIntent?.status).toBe("unavailable");
  expect(loaded.runningSessionId).toBe("native-codex-session");
  expect(canStopProvider(loaded)).toBe(true);
  expect(canStartProvider(loaded)).toBe(false);
});

test("malformed managed intent holds Codex without enabling the ordinary CLI path", () => {
  for (const intent of [
    null,
    {},
    { ...nativeCodexIntent, providerId: "claude" },
    { ...nativeCodexIntent, status: "running" },
    { ...nativeCodexIntent, executionDisclosure: "" },
    { ...nativeCodexIntent, executionDisclosure: "x".repeat(8193) },
  ]) {
    const rawContext = { ...context, nativeManagedIntent: intent } as AppContext;
    const loaded = reduceSession(initialState("react"), { type: "context", context: rawContext });
    expect(loaded.status).toBe("failed");
    expect(loaded.bootstrapError).toBeTruthy();
    expect(loaded.runningSessionId).toBeUndefined();
    expect(canStartProvider(loaded)).toBe(false);
    expect(canSelectProvider(loaded)).toBe(false);
  }
});

test("native execution disclosure survives metadata-free starts and held restores in both renderers", () => {
  for (const renderer of ["react", "solid"] as const) {
    for (const providerId of ["copilot", "codex"] as const) {
      for (const status of ["starting", "unavailable"] as const) {
        const loaded = reduceSession(initialState(renderer), {
          type: "context",
          context: {
            ...context, renderer, initialProviderId: providerId,
            nativeManagedIntent: { ...nativeCodexIntent, providerId, status },
          },
        });
        expect(managedExecutionDisclosure(loaded)).toBe(
          "Native-owned foreground OS-account execution; no sandbox.",
        );
      }
      const occupied = reduceSession(initialState(renderer), {
        type: "context",
        context: {
          ...context, renderer, initialProviderId: providerId,
          nativeManagedIntent: { ...nativeCodexIntent, providerId },
          nativeSession: { ...nativeCodexSession, providerId, executionDisclosure: "Current native snapshot disclosure." },
        },
      });
      expect(managedExecutionDisclosure(occupied)).toBe("Current native snapshot disclosure.");
    }
  }
});

test("native execution disclosure does not borrow manual or malformed session metadata", () => {
  const manual = reduceSession(initialState("react"), { type: "context", context });
  expect(managedExecutionDisclosure(manual)).toBe("");
  const malformed = reduceSession(initialState("solid"), {
    type: "context",
    context: {
      ...context, renderer: "solid",
      nativeManagedIntent: { ...nativeCodexIntent, executionDisclosure: "" },
      nativeSession: { ...nativeCodexSession, providerId: "copilot", executionDisclosure: "Foreign provider disclosure." },
    },
  });
  expect(malformed.status).toBe("failed");
  expect(managedExecutionDisclosure(malformed)).toBe("");
});

test("Solid auto-start projection retains managed intent after the native session exits", () => {
  const loaded = reduceSession(initialState("solid"), {
    type: "context",
    context: { ...context, renderer: "solid", nativeManagedIntent: nativeCodexIntent, nativeSession: nativeCodexSession },
  });
  const withProviders = reduceSession(loaded, { type: "providers", providers });
  const exited = reduceSession(withProviders, {
    type: "event",
    event: { type: "provider.exit", providerId: "codex", sessionId: "native-codex-session", status: 0 },
  });
  const projected = pickAutoStartState(exited);
  expect(projected.nativeManagedProviderId).toBe("codex");
  expect(canStartProvider(projected)).toBe(false);
  expect(shouldAutoStartProvider(projected)).toBe(false);
  const manual = reduceSession(
    reduceSession(initialState("solid"), { type: "context", context }),
    { type: "providers", providers },
  );
  expect(shouldAutoStartProvider(pickAutoStartState(manual))).toBe(true);
});

test("Solid auto-start memo comparison cannot erase a changed native ownership mode", () => {
  const manual = reduceSession(initialState("solid"), { type: "context", context });
  const managed = { ...manual, nativeManagedProviderId: "codex" as const };
  expect(autoStartStateEquals(manual, managed)).toBe(false);
  expect(autoStartStateEquals(manual, { ...manual })).toBe(true);
});
