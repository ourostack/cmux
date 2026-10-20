import { makeClientId } from "./ids";
import type { Action } from "./sessionModel";

export type ManagedComposerSnapshot = {
  editorText: string;
  editVersion: string;
  render: string;
};

export type ManagedComposerReceipt = { leaseId: string; render: string };

type EditorBinding = {
  element(): HTMLElement | null;
  text(): string;
  replace(text: string): void;
  eligible(): boolean;
};

// Renderer evidence only. This object cannot grant native command or writer authority.
export class ManagedComposer {
  private binding: EditorBinding | null = null;
  private editVersion = makeClientId();
  private readonly identity = makeClientId();
  private ownedMutation = false;
  private lease: { id: string; began: number; inserted: number; render: string | null } | null = null;
  private painted: string | null = null;
  private paintRequest = 0;
  private observer: MutationObserver | null = null;
  private unbind: (() => void) | null = null;

  bind(binding: EditorBinding): () => void {
    this.unbind?.();
    this.binding = binding;
    const document = binding.element()?.ownerDocument;
    const window = document?.defaultView;
    if (!document || !window) return () => { this.revoke(); };
    const invalidate = () => this.revoke();
    const input = (event: Event) => {
      if (!this.busy()) return;
      if (event.isTrusted) {
        this.revoke();
      } else if (event.cancelable) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    };
    const physicalEvents = ["beforeinput", "keydown", "pointerdown", "paste", "cut", "drop", "compositionstart"];
    for (const name of physicalEvents) document.addEventListener(name, input, true);
    document.addEventListener("focusout", invalidate, true);
    document.addEventListener("visibilitychange", invalidate, true);
    window.addEventListener("blur", invalidate, true);
    window.addEventListener("resize", invalidate, true);
    window.addEventListener("scroll", invalidate, true);
    const observer = new window.MutationObserver((records) => this.invalidateDOM(records));
    this.observer = observer;
    observer.observe(document.documentElement, { attributes: true, childList: true, characterData: true, subtree: true });
    this.schedulePaint();
    const cleanup = () => {
      this.revoke();
      window.cancelAnimationFrame(this.paintRequest);
      observer.disconnect();
      this.observer = null;
      for (const name of physicalEvents) document.removeEventListener(name, input, true);
      document.removeEventListener("focusout", invalidate, true);
      document.removeEventListener("visibilitychange", invalidate, true);
      window.removeEventListener("blur", invalidate, true);
      window.removeEventListener("resize", invalidate, true);
      window.removeEventListener("scroll", invalidate, true);
      this.binding = null;
      this.painted = null;
      this.unbind = null;
    };
    this.unbind = cleanup;
    return cleanup;
  }

  allowAction(action: Action): boolean {
    if (action.type === "setInput") {
      if (!this.allowMutation()) return false;
      this.editVersion = makeClientId();
    } else {
      this.revoke();
    }
    return true;
  }

  allowMutation(): boolean {
    return this.ownedMutation || !this.busy();
  }

  revoke(): void {
    this.lease = null;
  }

  capture(): ManagedComposerSnapshot | null {
    this.drainDOMChanges();
    if (this.busy()) return null;
    const snapshot = this.current();
    if (!snapshot || snapshot.render !== this.painted) {
      this.schedulePaint();
      return null;
    }
    return snapshot;
  }

  async reserve(snapshot: ManagedComposerSnapshot, text: string): Promise<ManagedComposerReceipt | null> {
    if (typeof text !== "string" || text.length === 0 || text.length > 256 * 1024) return null;
    const current = this.capture();
    if (!current || !snapshot || current.render !== snapshot.render ||
        current.editVersion !== snapshot.editVersion || current.editorText !== snapshot.editorText) return null;
    const binding = this.binding;
    const window = binding?.element()?.ownerDocument.defaultView;
    if (!binding || !window) return null;
    const outside = this.outsideComposer();
    if (outside === null) return null;
    const lease = { id: makeClientId(), began: performance.now(), inserted: performance.now(), render: null as string | null };
    this.lease = lease;
    this.ownedMutation = true;
    try {
      binding.replace(text);
    } catch (error) {
      this.revoke();
      throw error;
    } finally {
      this.ownedMutation = false;
    }
    lease.inserted = performance.now();
    const painted = await new Promise<boolean>((resolve) => {
      const timeout = window.setTimeout(() => {
        if (this.lease === lease) this.revoke();
        resolve(false);
      }, Math.max(0, 2000 - (performance.now() - lease.began)));
      window.requestAnimationFrame(() => window.requestAnimationFrame(() => {
        window.clearTimeout(timeout);
        resolve(true);
      }));
    });
    const inserted = this.current();
    if (!painted || !this.busy() || this.lease !== lease || !inserted || inserted.editorText !== text ||
        this.outsideComposer() !== outside) {
      if (this.lease === lease) this.revoke();
      return null;
    }
    lease.render = inserted.render;
    this.painted = inserted.render;
    return { leaseId: lease.id, render: inserted.render };
  }

  validate(receipt: ManagedComposerReceipt): boolean {
    this.drainDOMChanges();
    if (!this.busy()) return false;
    const lease = this.lease;
    if (!lease || !receipt || receipt.leaseId !== lease.id || receipt.render !== lease.render) return false;
    const current = this.current();
    if (!current || current.render !== lease.render) {
      this.revoke();
      return false;
    }
    return performance.now() - lease.inserted >= 150;
  }

  release(leaseId: string): void {
    if (this.lease?.id === leaseId) this.revoke();
  }

  private busy(): boolean {
    if (this.lease && performance.now() - this.lease.began >= 2000) this.revoke();
    return this.lease !== null;
  }

  private invalidateDOM(records: MutationRecord[]): void {
    this.painted = null;
    const composer = this.binding?.element()?.closest("form");
    if (this.lease && (this.lease.render !== null ||
        records.some((record) => !composer?.contains(record.target)))) this.revoke();
  }

  private drainDOMChanges(): void {
    const records = this.observer?.takeRecords();
    if (records?.length) this.invalidateDOM(records);
  }

  private schedulePaint(): void {
    const window = this.binding?.element()?.ownerDocument.defaultView;
    if (!window || this.paintRequest) return;
    this.paintRequest = window.requestAnimationFrame(() => {
      const before = this.current()?.render;
      this.paintRequest = window.requestAnimationFrame(() => {
        const after = this.current()?.render;
        this.painted = before && before === after ? after : null;
        this.paintRequest = 0;
      });
    });
  }

  private current(): ManagedComposerSnapshot | null {
    const binding = this.binding;
    const editor = binding?.element();
    const document = editor?.ownerDocument;
    const window = document?.defaultView;
    if (!binding || !editor || !document || !window || !binding.eligible() || !editor.isConnected ||
        document.visibilityState !== "visible" || !document.hasFocus() ||
        (document.activeElement !== editor && !editor.contains(document.activeElement))) return null;
    for (let node: HTMLElement | null = editor; node; node = node.parentElement) {
      const style = window.getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      if (node.hidden || style.display === "none" || style.visibility === "hidden" ||
          style.visibility === "collapse" || (style.opacity !== "" && Number(style.opacity) <= 0) ||
          rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0 ||
          rect.left >= window.innerWidth || rect.top >= window.innerHeight) return null;
    }
    const editorText = binding.text();
    const outside = canonicalDOM(document.body, editor, window);
    if (outside === null) return null;
    const selection = document.getSelection();
    const render = JSON.stringify({
      identity: this.identity, editVersion: this.editVersion, editorText, outside,
      editorDOM: editor instanceof window.HTMLTextAreaElement ? editor.value : editor.innerHTML,
      viewport: [window.innerWidth, window.innerHeight, window.scrollX, window.scrollY, window.devicePixelRatio],
      selection: editor instanceof window.HTMLTextAreaElement
        ? [editor.selectionStart, editor.selectionEnd, editor.selectionDirection]
        : [selection?.anchorOffset, selection?.focusOffset,
          selection?.anchorNode ? nodePath(selection.anchorNode, editor) : null,
          selection?.focusNode ? nodePath(selection.focusNode, editor) : null],
    });
    return render.length > 256 * 1024 ? null : { editorText, editVersion: this.editVersion, render };
  }

  private outsideComposer(): string | null {
    const editor = this.binding?.element();
    const window = editor?.ownerDocument.defaultView;
    if (!editor || !window) return null;
    return canonicalDOM(editor.ownerDocument.body, editor.closest("form") ?? editor, window);
  }
}

function nodePath(node: Node, root: HTMLElement): number[] | null {
  const path: number[] = [];
  let current: Node | null = node;
  while (current && current !== root) {
    const parent: ParentNode | null = current.parentNode;
    if (!parent) return null;
    path.unshift(Array.prototype.indexOf.call(parent.childNodes, current));
    current = parent;
  }
  return current === root ? path : null;
}

function canonicalDOM(root: HTMLElement, editor: Element, window: Window): string | null {
  let characters = 0;
  const visit = (node: Node): unknown => {
    if (node.nodeType === 3) {
      characters += node.textContent?.length ?? 0;
      return characters > 256 * 1024 ? null : node.textContent;
    }
    if (!(node instanceof root.ownerDocument.defaultView!.Element)) return null;
    const rect = node.getBoundingClientRect();
    const style = window.getComputedStyle(node);
    return [
      node.tagName,
      Array.from(node.attributes, (attribute) => [attribute.name, attribute.value]).sort(),
      [rect.x, rect.y, rect.width, rect.height, node.scrollTop, node.scrollLeft],
      [style.display, style.visibility, style.opacity, style.color, style.backgroundColor, style.font, style.transform],
      node === editor ? "managed-editor" : Array.from(node.childNodes, visit),
    ];
  };
  const result = JSON.stringify(visit(root));
  return characters > 256 * 1024 || result.length > 256 * 1024 ? null : result;
}
