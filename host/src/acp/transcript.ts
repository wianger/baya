import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { isObject } from "./jsonrpc.ts";
import type { SessionUpdate } from "./schema.ts";

/** Conversation updates kept for replay; the rest is session state. */
const CHUNKS = new Set(["user_message_chunk", "agent_message_chunk", "agent_thought_chunk"]);
const MAX_ENTRIES = 5_000;
const SAVE_DELAY_MS = 1_000;

export function isConversationUpdate(update: SessionUpdate): boolean {
  return (
    CHUNKS.has(update.sessionUpdate) ||
    update.sessionUpdate === "tool_call" ||
    update.sessionUpdate === "tool_call_update" ||
    update.sessionUpdate === "plan" ||
    update.sessionUpdate === "notice" ||
    update.sessionUpdate === "compaction_update" ||
    update.sessionUpdate === "compaction_summary_chunk"
  );
}

/**
 * The replayable history of one session, as ACP `session/update` payloads.
 *
 * Streaming arrives as many small chunks; consecutive text chunks of one
 * message are folded together and tool-call updates are folded into their
 * tool call, so a replay is short and shows each item in its final state.
 */
export class Transcript {
  private entries: SessionUpdate[] = [];
  private timer: NodeJS.Timeout | null = null;
  private readonly path: string | null;

  constructor(path: string | null) {
    this.path = path;
    if (path && existsSync(path)) {
      try {
        const document = JSON.parse(readFileSync(path, "utf8")) as { entries?: unknown };
        if (Array.isArray(document.entries)) {
          this.entries = document.entries.filter(
            (entry): entry is SessionUpdate =>
              isObject(entry) && typeof entry["sessionUpdate"] === "string",
          );
        }
      } catch {
        this.entries = [];
      }
    }
  }

  get updates(): readonly SessionUpdate[] {
    return this.entries;
  }

  append(update: SessionUpdate): void {
    if (!isConversationUpdate(update)) return;
    if (!this.fold(update)) this.entries.push(structuredClone(update));
    if (this.entries.length > MAX_ENTRIES) {
      this.entries.splice(0, this.entries.length - MAX_ENTRIES);
    }
    this.scheduleSave();
  }

  private fold(update: SessionUpdate): boolean {
    const last = this.entries.at(-1);
    switch (update.sessionUpdate) {
      case "user_message_chunk":
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        if (!last || last.sessionUpdate !== update.sessionUpdate) return false;
        if ((last["messageId"] ?? null) !== (update["messageId"] ?? null)) return false;
        const previous = last["content"];
        const next = update["content"];
        if (!isText(previous) || !isText(next)) return false;
        last["content"] = { ...previous, text: previous.text + next.text };
        return true;
      }
      case "tool_call":
      case "tool_call_update": {
        const target = this.findTool(update["toolCallId"]);
        if (!target) {
          if (update.sessionUpdate === "tool_call_update") {
            this.entries.push({
              ...structuredClone(update),
              sessionUpdate: "tool_call",
              title: "",
            });
            return true;
          }
          return false;
        }
        for (const [key, value] of Object.entries(update)) {
          if (key === "sessionUpdate" || value === null || value === undefined) continue;
          target[key] = structuredClone(value);
        }
        return true;
      }
      case "plan": {
        // A plan replaces the previous one of the same turn.
        for (let index = this.entries.length - 1; index >= 0; index--) {
          const entry = this.entries[index]!;
          if (entry.sessionUpdate === "user_message_chunk") break;
          if (entry.sessionUpdate === "plan") {
            this.entries[index] = structuredClone(update);
            return true;
          }
        }
        return false;
      }
      case "compaction_update": {
        const target = this.entries.findLast(
          (entry) =>
            entry.sessionUpdate === "compaction_update" &&
            entry["compactionId"] === update["compactionId"],
        );
        if (!target) return false;
        Object.assign(target, structuredClone(update));
        return true;
      }
      case "compaction_summary_chunk": {
        if (last?.sessionUpdate !== "compaction_summary_chunk") return false;
        if (last["compactionId"] !== update["compactionId"]) return false;
        const previous = last["content"];
        const next = update["content"];
        if (!isText(previous) || !isText(next)) return false;
        last["content"] = { ...previous, text: previous.text + next.text };
        return true;
      }
      default:
        return false;
    }
  }

  private findTool(id: unknown): SessionUpdate | undefined {
    if (typeof id !== "string") return undefined;
    return this.entries.findLast(
      (entry) => entry.sessionUpdate === "tool_call" && entry["toolCallId"] === id,
    );
  }

  private scheduleSave(): void {
    if (!this.path || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, SAVE_DELAY_MS);
    this.timer.unref();
  }

  flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (!this.path) return;
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.tmp`;
    writeFileSync(temporary, JSON.stringify({ version: 1, entries: this.entries }), {
      mode: 0o600,
    });
    renameSync(temporary, this.path);
  }

  /** Forgets the history on disk too. */
  destroy(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.entries = [];
    if (this.path) rmSync(this.path, { force: true });
  }
}

function isText(value: unknown): value is { type: "text"; text: string } {
  return isObject(value) && value["type"] === "text" && typeof value["text"] === "string";
}
