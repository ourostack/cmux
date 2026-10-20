import type { AgentEvent, AgentSessionTheme } from "./types";
import { makeClientId } from "./ids";
import { applyAgentTheme } from "./theme";
import type { ManagedComposer } from "./managedComposer";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type EventListener = (event: AgentEvent) => void;

declare global {
  interface Window {
    cmuxAgentBridge?: {
      applyTheme(theme: AgentSessionTheme): void;
      receive(event: AgentEvent): void;
      managedComposer?: Pick<ManagedComposer, "capture" | "reserve" | "validate" | "release" | "consume">;
    };
  }
}

const listeners = new Set<EventListener>();

export function installManagedComposer(composer: ManagedComposer): () => void {
  const bridge = window.cmuxAgentBridge;
  if (!bridge) throw new Error("Native renderer bridge is unavailable.");
  const operations = {
    capture: () => composer.capture(),
    reserve: (snapshot: Parameters<ManagedComposer["reserve"]>[0], text: string) => composer.reserve(snapshot, text),
    validate: (receipt: Parameters<ManagedComposer["validate"]>[0]) => composer.validate(receipt),
    release: (leaseId: string) => composer.release(leaseId),
    consume: (receipt: Parameters<ManagedComposer["consume"]>[0]) => composer.consume(receipt),
  };
  bridge.managedComposer = operations;
  const unsubscribe = subscribeToAgentEvents(() => composer.revoke());
  return () => {
    composer.revoke();
    unsubscribe();
    if (bridge.managedComposer === operations) delete bridge.managedComposer;
  };
}

export class NativeBridgeError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "NativeBridgeError";
    this.code = code;
  }
}

if (typeof window !== "undefined") {
  window.cmuxAgentBridge = {
    applyTheme(theme: AgentSessionTheme) {
      applyAgentTheme(theme);
    },
    receive(event: AgentEvent) {
      if (event.type === "app.theme") {
        applyAgentTheme(event.theme);
      }
      for (const listener of listeners) {
        listener(event);
      }
    },
  };
}

export function subscribeToAgentEvents(listener: EventListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export async function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (typeof window === "undefined") {
    throw new Error("Native bridge is unavailable.");
  }
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler || typeof handler.postMessage !== "function") {
    throw new Error("Native bridge is unavailable.");
  }

  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;

  if (!reply.ok) {
    throw new NativeBridgeError(reply.error?.userMessage || "Native bridge request failed.", reply.error?.code);
  }

  return reply.value;
}
