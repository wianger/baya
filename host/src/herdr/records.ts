/**
 * An agent's own record of a conversation, read as the chat the phone
 * shows. Claude Code, Codex and Pi each keep one JSONL file per session;
 * this turns each into the ACP `session/update`s the app already draws:
 * the user's and the agent's messages, thoughts, and tool calls with their
 * results, in order. The agent in its herdr pane is the only one writing;
 * Baya only reads, so the chat and the terminal never disagree.
 */
import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { isObject, type Json } from "../acp/jsonrpc.ts";

export type Update = Json;

/** Where [agent] keeps the conversation [sessionId] begun in [cwd]. */
export function locateRecord(agent: string, sessionId: string, cwd: string): string | null {
  const home = homedir();
  switch (agentFamily(agent)) {
    case "claude": {
      const file = join(home, ".claude", "projects", claudeFolder(cwd), `${sessionId}.jsonl`);
      return existsSync(file) ? file : null;
    }
    case "pi":
      return findFile(join(home, ".pi", "agent", "sessions"), (name) =>
        name.endsWith(`_${sessionId}.jsonl`),
      );
    case "codex":
      return findFile(join(home, ".codex", "sessions"), (name) =>
        name.endsWith(`-${sessionId}.jsonl`),
      );
    default:
      return null;
  }
}

/** The agent's conversations in [cwd], newest first: their ids and files. */
export function recordsIn(agent: string, cwd: string): { id: string; path: string; at: number }[] {
  const home = homedir();
  let files: string[] = [];
  switch (agentFamily(agent)) {
    case "claude": {
      const dir = join(home, ".claude", "projects", claudeFolder(cwd));
      files = existsSync(dir)
        ? readdirSync(dir)
            .filter((n) => n.endsWith(".jsonl"))
            .map((n) => join(dir, n))
        : [];
      break;
    }
    case "pi": {
      const dir = join(home, ".pi", "agent", "sessions", piFolder(cwd));
      files = existsSync(dir)
        ? readdirSync(dir)
            .filter((n) => n.endsWith(".jsonl"))
            .map((n) => join(dir, n))
        : [];
      break;
    }
    default:
      return [];
  }
  return files
    .map((path) => ({ path, id: idOf(agent, path), at: statSync(path).mtimeMs }))
    .filter((r) => r.id)
    .sort((a, b) => b.at - a.at);
}

/** claude, claude-code → claude; codex; pi. */
export function agentFamily(agent: string): "claude" | "codex" | "pi" | null {
  const a = agent.toLowerCase();
  if (a.startsWith("claude")) return "claude";
  if (a.startsWith("codex")) return "codex";
  if (a === "pi" || a.startsWith("pi-")) return "pi";
  return null;
}

function idOf(agent: string, path: string): string {
  const name = path.split(/[\\/]/u).pop() ?? "";
  switch (agentFamily(agent)) {
    case "claude":
      return name.replace(/\.jsonl$/u, "");
    case "pi":
      return (
        name
          .replace(/\.jsonl$/u, "")
          .split("_")
          .pop() ?? ""
      );
    default:
      return "";
  }
}

/** Claude Code's folder for a project: every other character a dash. */
export function claudeFolder(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9]/gu, "-");
}

/** Pi's: `--home-me-x--` for /home/me/x. */
function piFolder(cwd: string): string {
  return `--${cwd.replace(/^[\\/]+/u, "").replace(/[\\/:]+/gu, "-")}--`;
}

function findFile(root: string, match: (name: string) => boolean, depth = 4): string | null {
  if (!existsSync(root) || depth < 0) return null;
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isFile() && match(entry.name)) return path;
    if (entry.isDirectory()) {
      const found = findFile(path, match, depth - 1);
      if (found) return found;
    }
  }
  return null;
}

/** What has been read of a record: its lines so far, and where to go on. */
interface Read {
  bytes: number;
  partial: string;
  lines: Json[];
}

const reads = new Map<string, Read>();

/** Past this, a tool's output keeps its start and end only. */
const KEEP = 20_000;

const cutText = (text: string): string =>
  text.length <= KEEP ? text : `${text.slice(0, KEEP / 2)}\n…\n${text.slice(-KEEP / 2)}`;

/**
 * A line as the chat needs it: tool output cut to its start and end, and
 * images without their data (they are what makes records huge).
 */
function slim(line: Json): Json {
  const message = line["message"];
  if (!isObject(message) || !Array.isArray(message["content"])) return line;
  const shrink = (block: unknown): unknown => {
    if (!isObject(block)) return block;
    if (block["type"] === "image") return { type: "image" };
    if (typeof block["text"] === "string") return { ...block, text: cutText(block["text"]) };
    if (block["type"] === "tool_result") {
      const content = block["content"];
      return {
        ...block,
        content:
          typeof content === "string"
            ? cutText(content)
            : Array.isArray(content)
              ? content.map(shrink)
              : content,
      };
    }
    return block;
  };
  return { ...line, message: { ...message, content: message["content"].map(shrink) } };
}

/**
 * A record's lines, parsed once each: an agent only appends to its record,
 * so each read takes in what was added since the last (a long Claude
 * conversation's record runs to hundreds of megabytes).
 */
export function recordLines(path: string): Json[] {
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    reads.delete(path);
    return [];
  }
  let read = reads.get(path);
  // Rewritten, not appended to: start over.
  if (!read || size < read.bytes) read = { bytes: 0, partial: "", lines: [] };
  if (size > read.bytes) {
    const fd = openSync(path, "r");
    try {
      const buffer = Buffer.alloc(size - read.bytes);
      const got = readSync(fd, buffer, 0, buffer.length, read.bytes);
      read.bytes += got;
      const text = read.partial + buffer.subarray(0, got).toString("utf8");
      const cut = text.lastIndexOf("\n");
      read.partial = cut < 0 ? text : text.slice(cut + 1);
      for (const line of cut < 0 ? [] : text.slice(0, cut).split("\n")) {
        if (!line.trim()) continue;
        try {
          const value: unknown = JSON.parse(line);
          if (isObject(value)) read.lines.push(slim(value));
        } catch {
          // A line still being written is skipped; whole ones always parse.
        }
      }
    } finally {
      closeSync(fd);
    }
  }
  reads.set(path, read);
  return read.lines;
}

/** The record's conversation as chat updates, and the title it gives. */
export function readRecord(
  agent: string,
  path: string,
): { updates: Update[]; title: string | null; usage?: RecordUsage | null } {
  const lines = recordLines(path);
  const usage = usageOf(agent, lines);
  switch (agentFamily(agent)) {
    case "claude":
      return { ...fromClaude(lines), usage };
    case "pi":
      return { ...fromPi(lines), usage };
    case "codex":
      return { ...fromCodex(lines), usage };
    default:
      return { updates: [], title: null, usage };
  }
}

/** How full the context is: what its last reply was sent with. */
export interface RecordUsage {
  used: number;
  /** Tokens it holds; 0 when not known here. */
  size: number;
  /** The model that last replied, as the record names it. */
  model: string | null;
}

const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : 0);

export function usageOf(agent: string, lines: Json[]): RecordUsage | null {
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]!;
    const message = line["message"] as Json | undefined;
    const usage = message?.["usage"] as Json | undefined;
    if (!usage || !isObject(usage)) continue;
    switch (agentFamily(agent)) {
      case "claude": {
        if (line["type"] !== "assistant") continue;
        const used =
          num(usage["input_tokens"]) +
          num(usage["cache_creation_input_tokens"]) +
          num(usage["cache_read_input_tokens"]) +
          num(usage["output_tokens"]);
        // Claude Code's window: 200K, or 1M once a conversation is past it.
        return { used, size: used > 200_000 ? 1_000_000 : 200_000, model: null };
      }
      case "pi": {
        if (message?.["role"] !== "assistant") continue;
        const used =
          num(usage["input"]) +
          num(usage["cacheRead"]) +
          num(usage["cacheWrite"]) +
          num(usage["output"]);
        const provider = typeof message["provider"] === "string" ? message["provider"] : "";
        const model = typeof message["model"] === "string" ? message["model"] : "";
        return { used, size: 0, model: provider && model ? `${provider}/${model}` : null };
      }
      default:
        return null;
    }
  }
  return null;
}

// ── updates ─────────────────────────────────────────────────────────────

const text = (kind: string, value: string, messageId: string): Update => ({
  sessionUpdate: kind,
  messageId,
  content: { type: "text", text: value },
});

function toolCall(id: string, name: string, input: unknown): Update {
  const args = isObject(input) ? input : {};
  const lower = name.toLowerCase();
  const field = (...keys: string[]) => {
    for (const key of keys) {
      const value = args[key];
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return null;
  };
  const command = field("command", "cmd");
  const path = field("file_path", "path", "notebook_path");
  const pattern = field("pattern", "query");
  const kind = /bash|shell|exec|command/u.test(lower)
    ? "execute"
    : /^(read|view|cat)/u.test(lower)
      ? "read"
      : /edit|write|patch|multiedit/u.test(lower)
        ? "edit"
        : /grep|glob|search|find/u.test(lower)
          ? "search"
          : /fetch|web/u.test(lower)
            ? "fetch"
            : "other";
  const title =
    kind === "execute" && command
      ? command.split("\n")[0]!
      : path
        ? `${name} ${path}`
        : pattern
          ? `${name} ${pattern}`
          : name;
  return {
    sessionUpdate: "tool_call",
    toolCallId: id,
    title,
    kind,
    status: "in_progress",
    rawInput: args,
    ...(path ? { locations: [{ path }] } : {}),
  };
}

function toolResult(id: string, output: string, failed: boolean): Update {
  return {
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    status: failed ? "failed" : "completed",
    content: output ? [{ type: "content", content: { type: "text", text: output } }] : [],
  };
}

const blocks = (content: unknown): Json[] =>
  Array.isArray(content)
    ? content.filter(isObject)
    : typeof content === "string"
      ? [{ type: "text", text: content }]
      : [];

const plain = (content: unknown): string =>
  blocks(content)
    .map((b) => (typeof b["text"] === "string" ? b["text"] : ""))
    .join("\n");

/** Text a person typed: not a command echo, a hook note or a reminder. */
function isPersonText(value: string): boolean {
  const t = value.trim();
  return (
    t.length > 0 &&
    !t.startsWith("<command-") &&
    !t.startsWith("<local-command") &&
    !t.startsWith("<system-reminder>") &&
    !t.startsWith("<task-notification>") &&
    !t.startsWith("Caveat:") &&
    !t.startsWith("[Request interrupted")
  );
}

// ── Claude Code ─────────────────────────────────────────────────────────

function fromClaude(lines: Json[]): { updates: Update[]; title: string | null } {
  let title: string | null = null;
  const byId = new Map<string, Json>();
  let last: Json | null = null;
  for (const line of lines) {
    if (line["type"] === "ai-title" && typeof line["aiTitle"] === "string") title = line["aiTitle"];
    if (line["type"] === "custom-title" && typeof line["customTitle"] === "string") {
      title = line["customTitle"];
    }
    if (line["isSidechain"] === true) continue;
    // Every entry with an id is a link in the chain (attachments and
    // system notes sit between messages); only messages are shown.
    if (typeof line["uuid"] === "string") byId.set(line["uuid"], line);
    if (line["type"] === "user" || line["type"] === "assistant") last = line;
  }
  // The live branch: from the newest message back through its parents, so
  // a rewound conversation shows as it now stands.
  const chain: Json[] = [];
  const seen = new Set<Json>();
  for (let at: Json | undefined = last ?? undefined; at && !seen.has(at); ) {
    seen.add(at);
    chain.push(at);
    // A compacted conversation continues from before the summary.
    const parent = at["parentUuid"] ?? at["logicalParentUuid"];
    at = typeof parent === "string" ? byId.get(parent) : undefined;
  }
  chain.reverse();
  const updates: Update[] = [];
  for (const line of chain) {
    if (line["type"] !== "user" && line["type"] !== "assistant") continue;
    const message = isObject(line["message"]) ? line["message"] : {};
    const id = typeof line["uuid"] === "string" ? line["uuid"] : String(updates.length);
    if (line["type"] === "user") {
      if (line["isMeta"] === true) continue;
      for (const block of blocks(message["content"])) {
        if (block["type"] === "tool_result") {
          const out =
            typeof block["content"] === "string" ? block["content"] : plain(block["content"]);
          updates.push(toolResult(String(block["tool_use_id"]), out, block["is_error"] === true));
        } else if (block["type"] === "text" && typeof block["text"] === "string") {
          if (isPersonText(block["text"]))
            updates.push(text("user_message_chunk", block["text"], id));
        }
      }
    } else {
      const messageId = typeof message["id"] === "string" ? message["id"] : id;
      for (const block of blocks(message["content"])) {
        if (block["type"] === "text" && typeof block["text"] === "string" && block["text"].trim()) {
          updates.push(text("agent_message_chunk", block["text"], messageId));
        } else if (
          block["type"] === "thinking" &&
          typeof block["thinking"] === "string" &&
          block["thinking"].trim()
        ) {
          updates.push(text("agent_thought_chunk", block["thinking"], `${messageId}:thought`));
        } else if (block["type"] === "tool_use") {
          updates.push(
            toolCall(String(block["id"]), String(block["name"] ?? "tool"), block["input"]),
          );
        }
      }
    }
  }
  return { updates, title };
}

// ── Pi ──────────────────────────────────────────────────────────────────

function fromPi(lines: Json[]): { updates: Update[]; title: string | null } {
  const byId = new Map<string, Json>();
  let last: Json | null = null;
  let title: string | null = null;
  for (const line of lines) {
    if (line["type"] === "session_info" && typeof line["name"] === "string") title = line["name"];
    if (line["type"] !== "message") continue;
    if (typeof line["id"] === "string") byId.set(line["id"], line);
    last = line;
  }
  const chain: Json[] = [];
  const seen = new Set<Json>();
  for (let at: Json | undefined = last ?? undefined; at && !seen.has(at); ) {
    seen.add(at);
    chain.push(at);
    const parent = at["parentId"];
    at = typeof parent === "string" ? byId.get(parent) : undefined;
  }
  chain.reverse();
  const updates: Update[] = [];
  for (const line of chain) {
    const message = isObject(line["message"]) ? line["message"] : {};
    const id = String(line["id"]);
    const role = message["role"];
    if (role === "user") {
      const value = plain(message["content"]);
      if (isPersonText(value)) updates.push(text("user_message_chunk", value, id));
    } else if (role === "assistant") {
      for (const block of blocks(message["content"])) {
        if (block["type"] === "text" && typeof block["text"] === "string" && block["text"].trim()) {
          updates.push(text("agent_message_chunk", block["text"], id));
        } else if (
          block["type"] === "thinking" &&
          typeof block["thinking"] === "string" &&
          block["thinking"].trim()
        ) {
          updates.push(text("agent_thought_chunk", block["thinking"], `${id}:thought`));
        } else if (block["type"] === "toolCall") {
          updates.push(
            toolCall(String(block["id"]), String(block["name"] ?? "tool"), block["arguments"]),
          );
        }
      }
    } else if (role === "toolResult") {
      updates.push(
        toolResult(
          String(message["toolCallId"]),
          plain(message["content"]),
          message["isError"] === true,
        ),
      );
    }
  }
  return { updates, title };
}

// ── Codex ───────────────────────────────────────────────────────────────

function fromCodex(lines: Json[]): { updates: Update[]; title: string | null } {
  const updates: Update[] = [];
  let n = 0;
  for (const line of lines) {
    if (line["type"] !== "response_item") continue;
    const item = isObject(line["payload"]) ? line["payload"] : {};
    const id = typeof item["id"] === "string" ? item["id"] : `codex-${n++}`;
    switch (item["type"]) {
      case "message": {
        const value = blocks(item["content"])
          .map((b) => (typeof b["text"] === "string" ? b["text"] : ""))
          .join("\n");
        if (
          item["role"] === "user" &&
          isPersonText(value) &&
          !value.startsWith("<environment_context>")
        ) {
          updates.push(text("user_message_chunk", value, id));
        } else if (item["role"] === "assistant" && value.trim()) {
          updates.push(text("agent_message_chunk", value, id));
        }
        break;
      }
      case "reasoning": {
        const summary = blocks(item["summary"])
          .map((b) => (typeof b["text"] === "string" ? b["text"] : ""))
          .join("\n");
        if (summary.trim()) updates.push(text("agent_thought_chunk", summary, id));
        break;
      }
      case "function_call":
      case "custom_tool_call": {
        let input: unknown = item["input"] ?? item["arguments"];
        if (typeof input === "string") {
          try {
            input = JSON.parse(input);
          } catch {
            input = { command: input };
          }
        }
        updates.push(toolCall(String(item["call_id"]), String(item["name"] ?? "tool"), input));
        break;
      }
      case "function_call_output":
      case "custom_tool_call_output": {
        const output = item["output"];
        const value = typeof output === "string" ? output : plain(output);
        updates.push(toolResult(String(item["call_id"]), value, false));
        break;
      }
      default:
    }
  }
  return { updates, title: null };
}
