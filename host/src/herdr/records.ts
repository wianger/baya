/**
 * An agent's own record of a conversation, read as the chat the phone
 * shows. Claude Code, Codex and Pi each keep one JSONL file per session;
 * this turns each into the ACP `session/update`s the app already draws:
 * the user's and the agent's messages, thoughts, and tool calls with their
 * results, in order. The agent in its herdr pane is the only one writing;
 * Baya only reads, so the chat and the terminal never disagree.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
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

/** The record's conversation as chat updates, and the title it gives. */
export function readRecord(
  agent: string,
  path: string,
): { updates: Update[]; title: string | null } {
  let lines: Json[];
  try {
    lines = readFileSync(path, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .flatMap((line) => {
        try {
          const value: unknown = JSON.parse(line);
          return isObject(value) ? [value] : [];
        } catch {
          return [];
        }
      });
  } catch {
    return { updates: [], title: null };
  }
  switch (agentFamily(agent)) {
    case "claude":
      return fromClaude(lines);
    case "pi":
      return fromPi(lines);
    case "codex":
      return fromCodex(lines);
    default:
      return { updates: [], title: null };
  }
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
