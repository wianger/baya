/**
 * `baya attach`: a session of this computer's host in the terminal, live
 * alongside the phone. Both are clients of the same session, so what one
 * sends the other sees as it happens, and the agent has one conversation,
 * whichever agent it is.
 *
 * The screen is the conversation scrolling above a small live area: the
 * reply line being written, tools running, and a status line, with the
 * input under it.
 */
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";
import { createInterface, type Interface } from "node:readline";
import { isObject, type Json, JsonRpcPeer, type RpcId } from "../acp/jsonrpc.ts";
import { readControlInfo } from "../control/client.ts";

const ESC = "\x1b[";
const tty = () => Boolean(process.stdout.isTTY);
const style = (open: number, close: number) => (text: string) =>
  tty() ? `${ESC}${open}m${text}${ESC}${close}m` : text;
const bold = style(1, 22);
const dim = style(2, 22);
const italic = style(3, 23);
const red = style(31, 39);
const green = style(32, 39);
const yellow = style(33, 39);
const magenta = style(35, 39);
const cyan = style(36, 39);

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

interface SessionInfo {
  sessionId: string;
  cwd: string;
  title: string;
  updatedAt: string;
  agentName: string;
  working: boolean;
}

function sessionInfo(raw: Json): SessionInfo {
  const baya = isObject(raw["_meta"]) && isObject(raw["_meta"]["baya"]) ? raw["_meta"]["baya"] : {};
  return {
    sessionId: String(raw["sessionId"]),
    cwd: String(raw["cwd"] ?? ""),
    title: String(raw["title"] ?? ""),
    updatedAt: String(raw["updatedAt"] ?? ""),
    agentName: String(baya["agentName"] ?? baya["agent"] ?? ""),
    working: baya["working"] === true,
  };
}

/** The session [query] names (id prefix or words of its title), or the latest. */
export function pickSession(sessions: SessionInfo[], query: string | undefined): SessionInfo {
  const sorted = [...sessions].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  if (!query) {
    const latest = sorted[0];
    if (!latest) throw new Error("No sessions yet. Start one: baya open <folder>");
    return latest;
  }
  const lower = query.toLowerCase();
  const matches = sorted.filter(
    (s) => s.sessionId.startsWith(query) || s.title.toLowerCase().includes(lower),
  );
  if (matches.length === 0) throw new Error(`No session matches "${query}". See: baya status`);
  return matches[0]!;
}

// ── text ─────────────────────────────────────────────────────────────────────

// biome-ignore lint/suspicious/noControlCharactersInRegex: matches ANSI escapes.
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/gu;

/** Columns [text] takes: wide (CJK, full-width, emoji) characters take two. */
export function textWidth(text: string): number {
  let width = 0;
  for (const char of text.replace(ANSI, "")) {
    const code = char.codePointAt(0)!;
    if (code < 32 || (code >= 0x300 && code <= 0x36f) || code === 0x200d || code === 0xfe0f) {
      continue;
    }
    const wide =
      (code >= 0x1100 && code <= 0x115f) ||
      (code >= 0x2e80 && code <= 0xa4cf) ||
      (code >= 0xac00 && code <= 0xd7a3) ||
      (code >= 0xf900 && code <= 0xfaff) ||
      (code >= 0xfe30 && code <= 0xfe4f) ||
      (code >= 0xff00 && code <= 0xff60) ||
      (code >= 0xffe0 && code <= 0xffe6) ||
      (code >= 0x1f300 && code <= 0x1faff) ||
      (code >= 0x20000 && code <= 0x3fffd);
    width += wide ? 2 : 1;
  }
  return width;
}

/** Inline markdown: `code`, **bold**, *emphasis*. */
function inline(text: string): string {
  return text
    .replace(/`([^`]+)`/gu, (_, code: string) => cyan(code))
    .replace(/\*\*([^*]+)\*\*/gu, (_, strong: string) => bold(strong))
    .replace(
      /(^|[^*\w])\*([^*\s][^*]*)\*(?!\w)/gu,
      (_, before: string, em: string) => before + italic(em),
    );
}

const FENCE = /^\s*```/u;

function fence(text: string, opening: boolean): string {
  const language = text.trim().slice(3);
  return opening ? dim(`╭─ ${language || "code"}`) : dim("╰─");
}

/** Markdown a line at a time: headings, lists, quotes and fenced code. */
export class MarkdownLines {
  private fenced = false;

  /** A finished line, which may open or close a fence. */
  line(text: string): string {
    if (FENCE.test(text)) {
      const opening = !this.fenced;
      this.fenced = opening;
      return fence(text, opening);
    }
    return this.render(text, this.fenced);
  }

  /** The line still being written, shown without changing any state. */
  preview(text: string): string {
    return FENCE.test(text) ? fence(text, !this.fenced) : this.render(text, this.fenced);
  }

  private render(text: string, fenced: boolean): string {
    if (fenced) return `${dim("│")} ${text}`;
    const heading = /^(#{1,6})\s+(.*)$/u.exec(text);
    if (heading) return bold(inline(heading[2]!));
    const bullet = /^(\s*)[-*+]\s+(.*)$/u.exec(text);
    if (bullet) return `${bullet[1]}${dim("•")} ${inline(bullet[2]!)}`;
    const quote = /^>\s?(.*)$/u.exec(text);
    if (quote) return `${dim("▏")}${italic(inline(quote[1]!))}`;
    if (/^\s*([-*_])\1{2,}\s*$/u.test(text)) return dim("─".repeat(24));
    return inline(text);
  }

  reset(): void {
    this.fenced = false;
  }
}

// ── the socket ───────────────────────────────────────────────────────────────

/** The control socket in attach mode, as JSON-RPC lines. */
async function openSocket(): Promise<{
  socket: Socket;
  lines: (on: (line: string) => void) => void;
}> {
  const info = readControlInfo();
  if (!info) throw new Error("Baya is not running. Start it with `baya start`.");
  const socket = connect({ host: "127.0.0.1", port: info.port });
  socket.setEncoding("utf8");
  let buffer = "";
  let handler: ((line: string) => void) | null = null;
  const queue: string[] = [];
  socket.on("data", (chunk: string) => {
    buffer += chunk;
    for (let n = buffer.indexOf("\n"); n >= 0; n = buffer.indexOf("\n")) {
      const line = buffer.slice(0, n);
      buffer = buffer.slice(n + 1);
      if (handler) handler(line);
      else queue.push(line);
    }
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  socket.write(`${JSON.stringify({ token: info.token, id: randomUUID(), command: "attach" })}\n`);
  const first = await new Promise<string>((resolve, reject) => {
    handler = (line) => {
      handler = null;
      resolve(line);
    };
    socket.once("close", () => reject(new Error("Baya closed the connection.")));
  });
  const reply = JSON.parse(first) as { ok?: boolean; error?: string };
  if (!reply.ok) throw new Error(reply.error ?? "Baya refused to attach.");
  return {
    socket,
    lines: (on) => {
      handler = on;
      for (const line of queue.splice(0)) on(line);
    },
  };
}

// ── the screen ───────────────────────────────────────────────────────────────

/**
 * Lines go into the scrollback above a live area redrawn in place: what
 * [live] returns, then [status], then the input line under them.
 */
class Screen {
  rl: Interface | null = null;
  live: () => string[] = () => [];
  status: () => string = () => "";
  private drawnRows = 0;

  private rows(line: string): number {
    const columns = process.stdout.columns || 80;
    return Math.max(1, Math.ceil(textWidth(line) / columns));
  }

  /** Adds lines to the scrollback and redraws the live area under them. */
  print(...lines: string[]): void {
    if (!tty()) {
      if (lines.length) process.stdout.write(`${lines.join("\n")}\n`);
      return;
    }
    this.draw(lines);
  }

  draw(commit: string[] = []): void {
    if (!tty()) return;
    let out = "\r";
    if (this.drawnRows > 0) out += `${ESC}${this.drawnRows}A`;
    out += `${ESC}0J`;
    for (const line of commit) out += `${line}\n`;
    const area = [...this.live(), this.status()].filter((line) => line !== "");
    for (const line of area) out += `${line}\n`;
    this.drawnRows = area.reduce((sum, line) => sum + this.rows(line), 0);
    process.stdout.write(out);
    this.rl?.prompt(true);
  }

  /** Clears the live area, for good. */
  close(): void {
    if (tty()) {
      const up = this.drawnRows > 0 ? `${ESC}${this.drawnRows}A` : "";
      process.stdout.write(`\r${up}${ESC}0J`);
    }
    this.drawnRows = 0;
  }
}

function seconds(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
}

interface ConfigOption {
  id: string;
  category: string;
  currentValue: string;
  options: Array<{ value: string; name: string }>;
}

function configOptions(raw: unknown): ConfigOption[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(isObject).map((o) => ({
    id: String(o["id"]),
    category: String(o["category"] ?? ""),
    currentValue: String(o["currentValue"] ?? ""),
    options: (Array.isArray(o["options"]) ? o["options"] : [])
      .filter(isObject)
      .map((v) => ({ value: String(v["value"]), name: String(v["name"] ?? v["value"]) })),
  }));
}

const HELP = () => [
  `${bold("/model")}  choose the model`,
  `${bold("/stop")}   stop the turn ${dim("(Ctrl+C while it runs)")}`,
  `${bold("/quit")}   leave ${dim("(Ctrl+C when idle, or Ctrl+D)")}`,
  dim("Enter sends; the phone sees it too. Messages wait while the agent works."),
];

/** The text a finished tool printed, from its content blocks. */
function toolOutput(raw: Json): string {
  const blocks = Array.isArray(raw["content"]) ? raw["content"] : [];
  return blocks
    .filter(isObject)
    .map((b) =>
      isObject(b["content"]) && typeof b["content"]["text"] === "string"
        ? b["content"]["text"]
        : "",
    )
    .join("\n")
    .trimEnd();
}

export async function attach(query: string | undefined): Promise<void> {
  const { socket, lines } = await openSocket();
  const screen = new Screen();
  const markdown = new MarkdownLines();
  let sessionId = "";
  let agentName = "Agent";
  let working = false;
  let turnStarted = 0;
  let frame = 0;
  let config: ConfigOption[] = [];
  let usage: { used: number; size: number } | null = null;

  // What is being written now: the reply line, a thought, running tools.
  let partial = "";
  let block: string | null = null;
  let thoughtSince = 0;
  let lastUser: string | null = null;
  const tools = new Map<string, string>();

  /** A question waiting for a number typed: permission, or a choice. */
  let choice: {
    title: string;
    count: number;
    pick: (index: number | null) => void;
  } | null = null;
  /** Permission questions open, by request id, to withdraw when answered elsewhere. */
  const asked = new Map<RpcId, () => void>();

  const model = () => config.find((o) => o.category === "model");
  const modelName = () => {
    const m = model();
    return m?.options.find((o) => o.value === m.currentValue)?.name ?? m?.currentValue ?? "";
  };
  const spin = () => SPINNER[frame % SPINNER.length]!;

  screen.live = () => [
    ...[...tools.values()].map((title) => `${yellow(spin())} ${title}`),
    ...(partial ? [markdown.preview(partial)] : []),
  ];
  screen.status = () => {
    if (choice) {
      return yellow(`? ${choice.title} Type 1–${choice.count}, or Enter to skip.`);
    }
    const parts: string[] = [];
    if (working) {
      const doing = block === "thought" ? "thinking" : tools.size ? "using tools" : "working";
      parts.push(
        `${magenta(spin())} ${bold(agentName)} ${doing} ${dim(seconds(Date.now() - turnStarted))}`,
      );
    } else {
      parts.push(`${green("●")} ${bold(agentName)} ${dim("ready")}`);
    }
    const name = modelName();
    if (name) parts.push(dim(name));
    if (usage && usage.size > 0) {
      parts.push(dim(`context ${Math.round((usage.used / usage.size) * 100)}%`));
    }
    parts.push(dim(working ? "Ctrl+C stops" : "/help"));
    return parts.join(dim("  ·  "));
  };

  /** Ends the reply line and the thought shown, before something else. */
  const settle = (next: string | null) => {
    if (block === next) return;
    const commit: string[] = [];
    if (partial) {
      commit.push(markdown.line(partial));
      partial = "";
    }
    if (block === "thought" && thoughtSince) {
      commit.push(dim(italic(`✻ Thought for ${seconds(Date.now() - thoughtSince)}`)));
      thoughtSince = 0;
    }
    if (block === "agent") markdown.reset();
    block = next;
    if (commit.length) screen.print(...commit);
  };

  /** A finished tool: a line for good, with the end of what it printed. */
  const finishTool = (title: string, failed: boolean, raw: Json) => {
    const out = [`${failed ? red("✗") : green("✓")} ${dim(title)}`];
    const text = toolOutput(raw);
    if (text) {
      for (const line of text.split("\n").slice(-4)) out.push(dim(`  │ ${line.slice(0, 200)}`));
    }
    screen.print(...out);
  };

  const update = (raw: Json, replay: boolean) => {
    const kind = raw["sessionUpdate"];
    const content = isObject(raw["content"]) ? raw["content"] : {};
    const text = typeof content["text"] === "string" ? content["text"] : "";
    switch (kind) {
      case "user_message_chunk": {
        const id = String(raw["messageId"] ?? randomUUID());
        if (lastUser === id) return;
        settle(`user:${id}`);
        lastUser = id;
        if (!replay && !working) {
          working = true;
          turnStarted = Date.now();
        }
        screen.print("", `${cyan("▍")}${bold(text)}`, "");
        return;
      }
      case "agent_message_chunk": {
        settle("agent");
        partial += text;
        const end = partial.lastIndexOf("\n");
        if (end < 0) return screen.draw();
        const done = partial
          .slice(0, end)
          .split("\n")
          .map((line) => markdown.line(line));
        partial = partial.slice(end + 1);
        return screen.print(...done);
      }
      case "agent_thought_chunk":
        if (block !== "thought") {
          settle("thought");
          thoughtSince = Date.now();
        }
        return screen.draw();
      case "tool_call": {
        settle(null);
        const id = String(raw["toolCallId"]);
        const title = String(raw["title"] ?? "tool");
        const status = raw["status"];
        if (status === "completed" || status === "failed") {
          return finishTool(title, status === "failed", raw);
        }
        tools.set(id, title);
        return screen.draw();
      }
      case "tool_call_update": {
        const id = String(raw["toolCallId"]);
        const title = tools.get(id) ?? String(raw["title"] ?? "tool");
        const status = raw["status"];
        if (status === "completed" || status === "failed") {
          tools.delete(id);
          return finishTool(title, status === "failed", raw);
        }
        if (typeof raw["title"] === "string" && tools.has(id)) tools.set(id, raw["title"]);
        return screen.draw();
      }
      case "plan": {
        settle(null);
        const entries = (Array.isArray(raw["entries"]) ? raw["entries"] : []).filter(isObject);
        return screen.print(
          dim("Plan"),
          ...entries.map((entry) => {
            const status = entry["status"];
            const mark =
              status === "completed"
                ? green("✓")
                : status === "in_progress"
                  ? yellow("◐")
                  : dim("○");
            const line = String(entry["content"] ?? "");
            return `  ${mark} ${status === "completed" ? dim(line) : line}`;
          }),
        );
      }
      case "config_option_update":
        config = configOptions(raw["configOptions"]);
        return screen.draw();
      case "usage_update":
        if (typeof raw["used"] === "number" && typeof raw["size"] === "number") {
          usage = { used: raw["used"], size: raw["size"] };
          screen.draw();
        }
        return;
    }
  };

  const peer = new JsonRpcPeer({
    write: (message) => {
      if (!socket.destroyed) socket.write(`${JSON.stringify(message)}\n`);
    },
    onRequest: async (method, params, id) => {
      if (method === "session/request_permission") {
        settle(null);
        const call = isObject(params["toolCall"]) ? params["toolCall"] : {};
        const options = (Array.isArray(params["options"]) ? params["options"] : [])
          .filter(isObject)
          .map((o) => ({ optionId: String(o["optionId"]), name: String(o["name"]) }));
        screen.print(
          `${yellow("?")} ${bold(String(call["title"] ?? "The agent asks for permission"))}`,
          ...options.map((o, i) => `  ${yellow(String(i + 1))}  ${o.name}`),
        );
        return new Promise((answer) => {
          const cancelled = { outcome: { outcome: "cancelled" } };
          asked.set(id, () => answer(cancelled));
          choice = {
            title: "Allow it?",
            count: options.length,
            pick: (index) => {
              asked.delete(id);
              const picked = index === null ? undefined : options[index];
              answer(
                picked
                  ? { outcome: { outcome: "selected", optionId: picked.optionId } }
                  : cancelled,
              );
              screen.print(dim(`  → ${picked?.name ?? "skipped"}`));
            },
          };
          screen.draw();
        });
      }
      if (method === "elicitation/create") {
        screen.print(yellow("? The agent asks for details. Answer it on the phone."));
        return new Promise(() => {});
      }
      throw new Error(`Not handled here: ${method}`);
    },
    onNotification: (method, params) => {
      if (method === "session/update" && params["sessionId"] === sessionId) {
        if (isObject(params["update"])) update(params["update"], false);
      } else if (method === "_baya/session_changed" && isObject(params["session"])) {
        const info = sessionInfo(params["session"]);
        if (info.sessionId !== sessionId) return;
        if (info.working && !working) turnStarted = Date.now();
        if (!info.working && working) {
          settle(null);
          tools.clear();
        }
        working = info.working;
        screen.draw();
      } else if (method === "$/cancel_request") {
        const id = params["requestId"] as RpcId;
        const withdraw = asked.get(id);
        if (!withdraw) return;
        asked.delete(id);
        withdraw();
        choice = null;
        screen.print(dim("  Answered on the phone."));
      }
    },
  });

  // The history replays as updates before session/load answers.
  let replaying = true;
  lines((line) => {
    let message: Json;
    try {
      message = JSON.parse(line) as Json;
    } catch {
      return;
    }
    const params = isObject(message["params"]) ? message["params"] : {};
    if (
      replaying &&
      message["method"] === "session/update" &&
      params["sessionId"] === sessionId &&
      isObject(params["update"])
    ) {
      update(params["update"], true);
      return;
    }
    peer.receive(message);
  });

  await peer.request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {},
    clientInfo: { name: "baya-attach", title: "Baya terminal" },
  });
  const listed = await peer.request<{ sessions?: Json[] }>("session/list", {});
  const session = pickSession((listed.sessions ?? []).map(sessionInfo), query);
  sessionId = session.sessionId;
  agentName = session.agentName || "Agent";
  const rule = dim("─".repeat(Math.min(56, process.stdout.columns || 56)));
  process.stdout.write(
    `\n${bold(session.title || session.cwd)}\n${dim(`${agentName} · ${session.cwd}`)}\n${rule}\n`,
  );
  const loaded = await peer.request<Json>("session/load", {
    sessionId,
    cwd: session.cwd,
    mcpServers: [],
  });
  replaying = false;
  config = configOptions(loaded["configOptions"]);
  settle(null);
  tools.clear();
  working = session.working;
  if (working) turnStarted = Date.now();

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: tty() ? `${cyan("›")} ` : "",
  });
  screen.rl = rl;
  screen.draw();
  const ticker = setInterval(() => {
    frame++;
    if (working || tools.size) screen.draw();
  }, 100);

  await new Promise<void>((resolve) => {
    let closed = false;
    let lastInterrupt = 0;
    const quit = () => {
      if (closed) return;
      closed = true;
      clearInterval(ticker);
      settle(null);
      screen.rl = null;
      screen.close();
      rl.close();
      // Leave no handle behind: the socket goes now and stdin lets go.
      socket.destroy();
      process.stdin.pause();
      process.stdin.unref?.();
      resolve();
    };
    const stop = () => {
      peer.notify("session/cancel", { sessionId });
      screen.print(dim("Stopping the turn… Ctrl+C again to leave."));
    };
    const chooseModel = () => {
      const option = model();
      if (!option || option.options.length === 0) {
        return screen.print(dim("This agent has no models to choose from."));
      }
      screen.print(
        bold("Model"),
        ...option.options.map(
          (o, i) =>
            `  ${yellow(String(i + 1))}  ${o.name}${o.value === option.currentValue ? dim("  (now)") : ""}`,
        ),
      );
      choice = {
        title: "Which model?",
        count: option.options.length,
        pick: (index) => {
          const picked = index === null ? undefined : option.options[index];
          if (!picked) return;
          peer
            .request<Json>("session/set_config_option", {
              sessionId,
              configId: option.id,
              value: picked.value,
            })
            .then(
              (result) => {
                const next = configOptions(result["configOptions"]);
                config = next.length
                  ? next
                  : config.map((o) =>
                      o.id === option.id ? { ...o, currentValue: picked.value } : o,
                    );
                screen.print(dim(`  → ${picked.name}`));
              },
              (error: Error) => screen.print(red(`✗ ${error.message}`)),
            );
        },
      };
      screen.draw();
    };

    rl.on("line", (input) => {
      // Readline has echoed the line; the host echoes a sent message back.
      if (tty()) process.stdout.write(`${ESC}1A${ESC}2K`);
      const text = input.trim();
      const open = choice;
      if (open) {
        choice = null;
        const n = Number(text);
        open.pick(text && Number.isInteger(n) && n >= 1 && n <= open.count ? n - 1 : null);
        return screen.draw();
      }
      if (!text) return screen.draw();
      switch (text) {
        case "/quit":
        case "/exit":
          return quit();
        case "/help":
          return screen.print(...HELP());
        case "/stop":
          return working ? stop() : screen.print(dim("Nothing is running."));
        case "/model":
          return chooseModel();
      }
      peer
        .request("session/prompt", {
          sessionId,
          prompt: [{ type: "text", text }],
          _meta: { baya: { messageId: randomUUID() } },
        })
        .then(
          () => {
            settle(null);
            screen.draw();
          },
          (error: Error) => screen.print(red(`✗ ${error.message}`)),
        );
    });
    rl.on("SIGINT", () => {
      if (choice) {
        const open = choice;
        choice = null;
        open.pick(null);
        return screen.draw();
      }
      const now = Date.now();
      if (working && now - lastInterrupt > 1500) {
        lastInterrupt = now;
        return stop();
      }
      quit();
    });
    rl.on("close", quit);
    socket.on("close", () => {
      if (closed) return;
      screen.print(dim("Baya closed the connection."));
      quit();
    });
  });
}
