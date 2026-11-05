/**
 * `baya attach`: a session of this computer's host in the terminal, live
 * alongside the phone. Both are clients of the same session, so what one
 * sends the other sees as it happens, and the agent has one conversation,
 * whichever agent it is.
 *
 * The conversation scrolls above a small live area redrawn in place: the
 * reply line being written, tools running, and a rule carrying the status,
 * with the input under it.
 */
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { createInterface, type Interface } from "node:readline";
import { isObject, type Json, JsonRpcPeer, type RpcId } from "../acp/jsonrpc.ts";
import { readControlInfo } from "../control/client.ts";
import { box, c, hang, isTty, MarkdownLines, meter, rule, textWidth } from "./tui.ts";

const ESC = "\x1b[";
// Geometric shapes, which every terminal font has (braille is not a given).
const SPINNER = ["◐", "◓", "◑", "◒"];

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
 * Rows go into the scrollback above a live area redrawn in place: what
 * [live] returns, then [status], then the input line under them.
 */
class Screen {
  rl: Interface | null = null;
  live: () => string[] = () => [];
  status: () => string = () => "";
  private drawnRows = 0;
  private lastBlank = true;
  private lastSection: string | null = null;

  /**
   * Starts a section of [kind]: one blank row before it, unless the last
   * section was of the same kind and [kind] groups (a run of tools).
   */
  section(kind: string, groups = false): void {
    const same = groups && this.lastSection === kind;
    this.lastSection = kind;
    if (!same && !this.lastBlank) this.print("");
  }

  private rows(line: string): number {
    return Math.max(1, Math.ceil(textWidth(line) / (process.stdout.columns || 80)));
  }

  /** Adds rows to the scrollback and redraws the live area under them. */
  print(...lines: string[]): void {
    if (lines.length) this.lastBlank = lines[lines.length - 1] === "";
    if (!isTty()) {
      if (lines.length) process.stdout.write(`${lines.join("\n")}\n`);
      return;
    }
    this.draw(lines);
  }

  draw(commit: string[] = []): void {
    if (!isTty()) return;
    let out = "\r";
    if (this.drawnRows > 0) out += `${ESC}${this.drawnRows}A`;
    out += `${ESC}0J`;
    for (const line of commit) out += `${line}\n`;
    // One blank row between the conversation and what is live under it.
    const live = this.live().filter((line) => line !== "");
    const area = [
      ...(this.lastBlank ? [] : [""]),
      ...live,
      ...(live.length ? [""] : []),
      this.status(),
    ];
    for (const line of area) out += `${line}\n`;
    this.drawnRows = area.reduce((sum, line) => sum + this.rows(line), 0);
    process.stdout.write(out);
    this.rl?.prompt(true);
  }

  /** Clears the live area, for good. */
  close(): void {
    if (isTty()) {
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

/** A folder as people read it: ~ for home, the end kept when it is long. */
function folder(path: string): string {
  const home = homedir();
  const short = path.startsWith(home) ? `~${path.slice(home.length)}` : path;
  return short.length > 48 ? `…${short.slice(-47)}` : short;
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

const HELP = () =>
  box(
    [
      `${c.accent("/model")}   choose the model`,
      `${c.accent("/stop")}    stop the turn         ${c.faint("Ctrl+C while it runs")}`,
      `${c.accent("/quit")}    leave                 ${c.faint("Ctrl+C when idle · Ctrl+D")}`,
      "",
      c.muted("Enter sends. The phone sees it too; messages wait while the agent works."),
    ],
    { title: c.bold("Commands"), width: 72 },
  );

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
  const markdown = new MarkdownLines("  ");
  let sessionId = "";
  let agentName = "Agent";
  let working = false;
  let turnStarted = 0;
  let turnTools = 0;
  let frame = 0;
  let config: ConfigOption[] = [];
  let usage: { used: number; size: number } | null = null;

  // What is being written now: the reply line, a thought, running tools.
  let partial = "";
  let block: string | null = null;
  let firstRow = false;
  let thoughtSince = 0;
  let lastUser: string | null = null;
  const tools = new Map<string, string>();

  /** A question waiting for a number typed: permission, or a choice. */
  let choice: { title: string; count: number; pick: (index: number | null) => void } | null = null;
  /** Permission questions open, by request id, to withdraw when answered elsewhere. */
  const asked = new Map<RpcId, () => void>();

  const model = () => config.find((o) => o.category === "model");
  const modelName = () => {
    const m = model();
    return m?.options.find((o) => o.value === m.currentValue)?.name ?? m?.currentValue ?? "";
  };
  const spin = () => SPINNER[frame % SPINNER.length]!;

  /** Reply rows; the first of a reply carries its marker. */
  const reply = (rows: string[]) =>
    rows.map((row) => {
      if (!firstRow || row === "") return row;
      firstRow = false;
      return `${c.accent("●")} ${row.startsWith("  ") ? row.slice(2) : row}`;
    });

  screen.live = () => [
    ...[...tools.values()].flatMap((title) => hang(title, `${c.accent(spin())} `, "  ")),
    ...(partial
      ? markdown
          .preview(partial)
          .map((row, i) =>
            i === 0 && firstRow
              ? `${c.accent("●")} ${row.startsWith("  ") ? row.slice(2) : row}`
              : row,
          )
      : []),
    "",
  ];
  screen.status = () => {
    if (choice) {
      return rule(
        `${c.accent("?")} ${c.bold(choice.title)}`,
        c.muted(`1–${choice.count} · Enter skips`),
        c.accent,
      );
    }
    const left = working
      ? `${c.violet(spin())} ${c.bold(agentName)} ${c.muted(
          block === "thought" ? "thinking" : tools.size ? "using tools" : "working",
        )} ${c.faint(seconds(Date.now() - turnStarted))}`
      : `${c.green("●")} ${c.bold(agentName)} ${c.muted("ready")}`;
    const right: string[] = [];
    const name = modelName();
    if (name) right.push(c.muted(name));
    if (usage && usage.size > 0) {
      const f = usage.used / usage.size;
      right.push(`${meter(f)} ${c.muted(`${Math.round(f * 100)}%`)}`);
    }
    right.push(c.faint(working ? "Ctrl+C stops" : "/help"));
    return rule(left, right.join(c.faint("  ·  ")));
  };

  /** Ends the reply line and the thought shown, before something else. */
  const settle = (next: string | null) => {
    if (block === next) return;
    const commit: string[] = [];
    if (partial) {
      commit.push(...reply(markdown.line(partial)));
      partial = "";
    }
    if (block === "agent") markdown.reset();
    if (commit.length) screen.print(...commit);
    if (block === "thought" && thoughtSince) {
      screen.section("thought");
      screen.print(c.italic(c.muted(`✻ Thought for ${seconds(Date.now() - thoughtSince)}`)));
      thoughtSince = 0;
    }
    block = next;
  };

  /** A finished tool: a line for good, with the end of what it printed. */
  const finishTool = (title: string, failed: boolean, raw: Json) => {
    turnTools++;
    screen.section("tool", true);
    const out = hang(c.bold(title), `${failed ? c.red("●") : c.green("●")} `, "  ");
    const text = toolOutput(raw);
    if (text) {
      const tail = text
        .split("\n")
        .filter((line) => line.trim() !== "")
        .slice(-4);
      for (const line of tail) {
        out.push(...hang(c.faint(line.slice(0, 400)), c.faint("  │ "), c.faint("  │ ")));
      }
    }
    screen.print(...out);
  };

  /** The end of a turn: how long it took and what it used. */
  const turnEnded = () => {
    if (!turnStarted) return;
    screen.section("end");
    const took = seconds(Date.now() - turnStarted);
    const used = turnTools ? ` · ${turnTools} tool${turnTools === 1 ? "" : "s"}` : "";
    screen.print(c.faint(`└ ${took}${used}`), "");
    turnStarted = 0;
    turnTools = 0;
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
          turnTools = 0;
        }
        screen.section("user");
        return screen.print(...hang(c.bold(text), `${c.accent("›")} `, "  "));
      }
      case "agent_message_chunk": {
        if (block !== "agent") {
          settle("agent");
          screen.section("agent");
          firstRow = true;
        }
        partial += text;
        const end = partial.lastIndexOf("\n");
        if (end < 0) return screen.draw();
        const done = partial
          .slice(0, end)
          .split("\n")
          .flatMap((line) => reply(markdown.line(line)));
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
        screen.section("plan");
        const entries = (Array.isArray(raw["entries"]) ? raw["entries"] : []).filter(isObject);
        return screen.print(
          `${c.accent("◆")} ${c.bold("Plan")}`,
          ...entries.flatMap((entry) => {
            const status = entry["status"];
            const line = String(entry["content"] ?? "");
            if (status === "completed") return hang(c.faint(line), `  ${c.green("✓")} `, "    ");
            if (status === "in_progress") return hang(c.bold(line), `  ${c.accent("◐")} `, "    ");
            return hang(line, `  ${c.faint("○")} `, "    ");
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
          .map((o) => ({
            optionId: String(o["optionId"]),
            name: String(o["name"]),
            kind: String(o["kind"] ?? ""),
          }));
        const title = String(call["title"] ?? tools.get(String(call["toolCallId"])) ?? "");
        screen.section("permission");
        screen.print(
          ...box(
            [
              c.bold(title || "The agent asks to go on."),
              "",
              ...options.map((o, i) => {
                const paint = o.kind.startsWith("reject")
                  ? c.red
                  : o.kind.startsWith("allow")
                    ? c.green
                    : c.text;
                return `${c.accent(String(i + 1))}  ${paint(o.name)}`;
              }),
            ],
            {
              title: c.bold(c.accent("Permission")),
              foot: c.muted("a number · or on the phone"),
              color: c.accent,
              width: 72,
            },
          ),
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
              screen.print(c.muted(`  → ${picked?.name ?? "skipped"}`), "");
            },
          };
          screen.draw();
        });
      }
      if (method === "elicitation/create") {
        screen.print(
          `${c.accent("?")} ${c.muted("The agent asks for details. Answer it on the phone.")}`,
        );
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
        if (info.working && !working) {
          turnStarted = Date.now();
          turnTools = 0;
        }
        if (!info.working && working) {
          settle(null);
          tools.clear();
          turnEnded();
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
        screen.print(c.muted("  Answered on the phone."), "");
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
  const header = (model: string) =>
    box(
      [
        c.bold(session.title || folder(session.cwd)),
        c.muted([agentName, model, folder(session.cwd)].filter(Boolean).join("  ·  ")),
      ],
      {
        title: `${c.accent("◆")} ${c.bold("Baya")}`,
        foot: c.faint("live with your phone"),
        width: 72,
      },
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
  // The header goes last, so it is what one sees above the input.
  screen.print("", ...header(modelName()), "");
  working = session.working;
  if (working) turnStarted = Date.now();

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: isTty() ? `${c.accent("❯")} ` : "",
  });
  screen.rl = rl;
  screen.draw();
  const ticker = setInterval(() => {
    frame++;
    if (working || tools.size) screen.draw();
  }, 150);
  process.stdout.on("resize", () => screen.draw());

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
      screen.print(c.muted("  Stopping the turn… Ctrl+C again to leave."));
    };
    const chooseModel = () => {
      const option = model();
      if (!option || option.options.length === 0) {
        return screen.print(c.muted("  This agent has no models to choose from."));
      }
      screen.print(
        ...box(
          option.options.map(
            (o, i) =>
              `${c.accent(String(i + 1))}  ${o.value === option.currentValue ? c.bold(o.name) : o.name}${
                o.value === option.currentValue ? c.green("  ✓") : ""
              }`,
          ),
          { title: c.bold("Model"), foot: c.muted("a number · Enter keeps it"), width: 72 },
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
                screen.print(c.muted(`  → ${picked.name}`), "");
              },
              (error: Error) => screen.print(`${c.red("✗")} ${error.message}`),
            );
        },
      };
      screen.draw();
    };

    rl.on("line", (input) => {
      // Readline has echoed the line; the host echoes a sent message back.
      if (isTty()) process.stdout.write(`${ESC}1A${ESC}2K`);
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
          return working ? stop() : screen.print(c.muted("  Nothing is running."));
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
          (error: Error) => screen.print(`${c.red("✗")} ${error.message}`),
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
      screen.print(c.muted("  Baya closed the connection."));
      quit();
    });
  });
}
