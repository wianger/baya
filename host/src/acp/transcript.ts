import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { TerminalSnapshot } from "./client_services.ts";
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

/** The longest string kept in a tool's raw input or output. */
const RAW_TEXT_LIMIT = 32 * 1024;

/**
 * A tool call as phones need it. `rawInput` and `rawOutput` are the
 * agent's own records, shown only when a tool has no content: images in
 * them (an agent reading a photo puts its base64 there) are dropped and
 * long text is cut. A conversation that read a few photos was 20 MB, nearly
 * all of it there, sent to the phone on every open.
 */
export function slim(update: SessionUpdate): SessionUpdate {
  if (update.sessionUpdate !== "tool_call" && update.sessionUpdate !== "tool_call_update") {
    return update;
  }
  const content = update["content"];
  const diffs =
    Array.isArray(content) && content.some((block) => isObject(block) && block["type"] === "diff");
  if (update["rawInput"] === undefined && update["rawOutput"] === undefined && !diffs)
    return update;
  const out: SessionUpdate = { ...update };
  for (const key of ["rawInput", "rawOutput"]) {
    if (out[key] !== undefined) out[key] = slimRaw(out[key], 0);
  }
  if (diffs) {
    out["content"] = (content as unknown[]).map((block) =>
      isObject(block) && block["type"] === "diff" ? trimDiff(block) : block,
    );
  }
  return out;
}

/** Unchanged lines kept around a change when a diff is trimmed. */
const DIFF_CONTEXT = 3;

/**
 * Some agents report an edit as the whole file before and after, 70 KB
 * for a one-line change. Long unchanged runs before the first change and
 * after the last are left out, and `_meta.baya.firstLine` says where the
 * texts now start, so line numbers stay true.
 */
export function trimDiff(block: Record<string, unknown>): Record<string, unknown> {
  const before = block["oldText"];
  const after = block["newText"];
  if (typeof before !== "string" || before === "" || typeof after !== "string") return block;
  if (before.length + after.length < 8 * 1024) return block;
  const a = before.split("\n");
  const b = after.split("\n");
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tail = 0;
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  ) {
    tail++;
  }
  const from = Math.max(0, head - DIFF_CONTEXT);
  const cut = Math.max(0, tail - DIFF_CONTEXT);
  if (from === 0 && cut === 0) return block;
  const meta = isObject(block["_meta"]) ? block["_meta"] : {};
  const baya = isObject(meta["baya"]) ? meta["baya"] : {};
  const previous = typeof baya["firstLine"] === "number" ? baya["firstLine"] : 1;
  return {
    ...block,
    oldText: a.slice(from, a.length - cut).join("\n"),
    newText: b.slice(from, b.length - cut).join("\n"),
    _meta: { ...meta, baya: { ...baya, firstLine: previous + from } },
  };
}

function slimRaw(value: unknown, depth: number): unknown {
  if (typeof value === "string") {
    return value.length > RAW_TEXT_LIMIT
      ? `${value.slice(0, RAW_TEXT_LIMIT)}… (${Math.round((value.length - RAW_TEXT_LIMIT) / 1024)} KB more)`
      : value;
  }
  if (depth > 12 || value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map((item) => slimRaw(item, depth + 1));
  const record = value as Record<string, unknown>;
  const binary =
    (record["type"] === "image" || record["type"] === "audio" || record["type"] === "blob") &&
    typeof record["data"] === "string";
  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(record)) {
    if (binary && key === "data") continue;
    if (key === "blob" && typeof item === "string" && item.length > 1024) continue;
    out[key] = slimRaw(item, depth + 1);
  }
  return out;
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
  private readonly terminalOutput = new Map<string, TerminalSnapshot>();
  private timer: NodeJS.Timeout | null = null;
  private readonly path: string | null;

  constructor(path: string | null) {
    this.path = path;
    if (path && existsSync(path)) {
      try {
        const document = JSON.parse(readFileSync(path, "utf8")) as {
          entries?: unknown;
          terminals?: unknown;
        };
        if (Array.isArray(document.terminals)) {
          for (const terminal of document.terminals as TerminalSnapshot[]) {
            if (typeof terminal?.terminalId === "string") {
              this.terminalOutput.set(terminal.terminalId, terminal);
            }
          }
        }
        if (Array.isArray(document.entries)) {
          this.entries = document.entries
            .filter(
              (entry): entry is SessionUpdate =>
                isObject(entry) && typeof entry["sessionUpdate"] === "string",
            )
            .map(slim);
        }
      } catch {
        this.entries = [];
      }
    }
  }

  get updates(): readonly SessionUpdate[] {
    return this.entries;
  }

  /** The latest output of every terminal the conversation ran. */
  get terminals(): TerminalSnapshot[] {
    return [...this.terminalOutput.values()];
  }

  setTerminal(snapshot: TerminalSnapshot): void {
    this.terminalOutput.set(snapshot.terminalId, snapshot);
    if (this.terminalOutput.size > 200) {
      this.terminalOutput.delete(this.terminalOutput.keys().next().value!);
    }
    this.scheduleSave();
  }

  append(update: SessionUpdate): void {
    if (!isConversationUpdate(update)) return;
    update = slim(update);
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
    writeFileSync(
      temporary,
      JSON.stringify({ version: 1, entries: this.entries, terminals: this.terminals }),
      {
        mode: 0o600,
      },
    );
    renameSync(temporary, this.path);
  }

  /** Forgets the history on disk too. */
  destroy(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.entries = [];
    this.terminalOutput.clear();
    if (this.path) rmSync(this.path, { force: true });
  }
}

function isText(value: unknown): value is { type: "text"; text: string } {
  return isObject(value) && value["type"] === "text" && typeof value["text"] === "string";
}
