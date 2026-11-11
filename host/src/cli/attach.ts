/**
 * `baya attach`: a session of this computer's host in the terminal, live
 * alongside the phone. Both are clients of the same session, so what one
 * sends the other sees as it happens, and the agent has one conversation,
 * whichever agent it is.
 *
 * The look follows today's agent terminals: the conversation scrolls above
 * a live area redrawn in place (a shimmering "Thinking…", tools running),
 * the input sits in a rounded box with a footer under it, questions are
 * menus moved through with the arrows, and Esc interrupts.
 */
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { createInterface, emitKeypressEvents } from "node:readline";
import { isObject, type Json, JsonRpcPeer, type RpcId } from "../acp/jsonrpc.ts";
import { readControlInfo } from "../control/client.ts";
import { Editor } from "./editor.ts";
import {
  band,
  c,
  clip,
  diffRows,
  gradient,
  hang,
  isTty,
  MarkdownLines,
  meter,
  shimmer,
  textWidth,
  wrap,
} from "./tui.ts";

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

/** The width to draw to: one short of the terminal, so no row ever wraps. */
const width = () => Math.max(30, Math.min((process.stdout.columns || 80) - 1, 140));

/** The live area: its rows, and where the caret goes among them. */
interface Region {
  rows: string[];
  caret: { row: number; column: number } | null;
}

/**
 * Rows go into the scrollback above the live area, which is redrawn in
 * place; the terminal's caret is put in the input box.
 */
class Screen {
  region: () => Region = () => ({ rows: [], caret: null });
  private caretRow = 0;
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
    const { rows, caret } = this.region();
    let out = `${ESC}?25l\r`;
    if (this.caretRow > 0) out += `${ESC}${this.caretRow}A`;
    out += `${ESC}0J`;
    for (const line of commit) out += `${line}\n`;
    // A live row that wrapped would throw off where the redraw starts.
    const w = width();
    const area = [...(this.lastBlank ? [] : [""]), ...rows.map((row) => clip(row, w))];
    out += area.join("\n");
    const at = caret ? caret.row + (area.length - rows.length) : area.length - 1;
    const up = area.length - 1 - at;
    if (up > 0) out += `${ESC}${up}A`;
    out += `\r${caret ? `${ESC}${caret.column + 1}G${ESC}?25h` : ""}`;
    this.caretRow = at;
    process.stdout.write(out);
  }

  /** Clears the live area for good and leaves the caret under the conversation. */
  close(): void {
    if (isTty()) {
      const up = this.caretRow > 0 ? `${ESC}${this.caretRow}A` : "";
      process.stdout.write(`\r${up}${ESC}0J${ESC}?25h`);
    }
    this.caretRow = 0;
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
  return short.length > 56 ? `…${short.slice(-55)}` : short;
}

/** [left] and [right] on one row of [w] columns. */
function spread(left: string, right: string, w: number): string {
  const gap = Math.max(2, w - textWidth(left) - textWidth(right));
  return left + " ".repeat(gap) + right;
}

/** A rounded box [w] wide around [rows], each already within the inside. */
function frame(
  rows: string[],
  w: number,
  options: { title?: string; foot?: string; paint?: (t: string) => string } = {},
): string[] {
  const paint = options.paint ?? c.faint;
  const inner = w - 4;
  const edge = (l: string, label: string | undefined, r: string) => {
    const tag = label ? ` ${label} ` : "";
    return paint(`${l}─`) + tag + paint(`${"─".repeat(Math.max(0, w - 3 - textWidth(tag)))}${r}`);
  };
  return [
    edge("╭", options.title, "╮"),
    ...rows.map(
      (row) =>
        `${paint("│")} ${row}${" ".repeat(Math.max(0, inner - textWidth(row)))} ${paint("│")}`,
    ),
    edge("╰", options.foot, "╯"),
  ];
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

/** Baya's own commands; the agent's (`/compact`…) are listed after them. */
const COMMANDS: Array<[string, string]> = [
  ["/model", "choose the model"],
  ["/rename", "name this session"],
  ["/stop", "interrupt the turn"],
  ["/clear", "clear the screen"],
  ["/help", "keys and commands"],
  ["/quit", "leave"],
];

/** What a tool did, as Claude Code and Codex name it: Run, Read, Edit… */
const KIND_LABEL: Record<string, string> = {
  execute: "Run",
  read: "Read",
  edit: "Edit",
  delete: "Delete",
  move: "Move",
  search: "Search",
  fetch: "Fetch",
  think: "Think",
};

/** `Run(npm test)`: the kind, then what it acted on. */
export function toolLabel(kind: string, title: string): string {
  const label = KIND_LABEL[kind];
  const target = title.replace(/`/gu, "").trim();
  if (!label) return c.bold(target || "Tool");
  const rest = target.toLowerCase().startsWith(label.toLowerCase())
    ? target.slice(label.length).trim()
    : target;
  return rest ? `${c.bold(label)}${c.muted(`(${rest})`)}` : c.bold(label);
}

interface ToolContent {
  text: string;
  diffs: Array<{ path: string; before: string; after: string }>;
}

/** What a finished tool printed, and the files it changed. */
function toolContent(raw: Json): ToolContent {
  const blocks = (Array.isArray(raw["content"]) ? raw["content"] : []).filter(isObject);
  return {
    text: blocks
      .map((b) =>
        isObject(b["content"]) && typeof b["content"]["text"] === "string"
          ? b["content"]["text"]
          : "",
      )
      .join("\n")
      .trimEnd(),
    diffs: blocks
      .filter((b) => b["type"] === "diff")
      .map((b) => ({
        path: String(b["path"] ?? ""),
        before: typeof b["oldText"] === "string" ? b["oldText"] : "",
        after: typeof b["newText"] === "string" ? b["newText"] : "",
      })),
  };
}

interface Choice {
  title: string;
  question: string;
  /** Rows shown above the question: what is being allowed. */
  detail?: string[];
  options: Array<{ label: string; paint?: (t: string) => string; note?: string }>;
  index: number;
  pick: (index: number | null) => void;
}

export async function attach(query: string | undefined): Promise<void> {
  const { socket, lines } = await openSocket();
  const screen = new Screen();
  const markdown = new MarkdownLines("  ", width);
  const editor = new Editor();
  let sessionId = "";
  let agentName = "Agent";
  let working = false;
  let turnStarted = 0;
  let turnTools = 0;
  let frameNo = 0;
  let config: ConfigOption[] = [];
  let usage: { used: number; size: number } | null = null;

  // What is being written now: the reply line, a thought, running tools.
  let partial = "";
  let block: string | null = null;
  let firstRow = false;
  let thoughtSince = 0;
  let thought = "";
  let lastUser: string | null = null;
  const tools = new Map<string, { kind: string; title: string; since: number }>();
  /** The agent's own slash commands, from `available_commands_update`. */
  let agentCommands: Array<[string, string]> = [];
  /** The highlighted row of the command menu under the input. */
  let commandIndex = 0;

  /** A menu waiting for a pick: permission, or the model. */
  let choice: Choice | null = null;
  /** Permission questions open, by request id, to withdraw when answered elsewhere. */
  const asked = new Map<RpcId, () => void>();

  const model = () => config.find((o) => o.category === "model");
  const modelName = () => {
    const m = model();
    return m?.options.find((o) => o.value === m.currentValue)?.name ?? m?.currentValue ?? "";
  };
  const spin = () => SPINNER[Math.floor(frameNo / 2) % SPINNER.length]!;
  const marker = (row: string) => `${c.accent("●")} ${row.startsWith("  ") ? row.slice(2) : row}`;

  /** Reply rows; the first of a reply carries its marker. */
  const reply = (rows: string[]) =>
    rows.map((row) => {
      if (!firstRow || row === "") return row;
      firstRow = false;
      return marker(row);
    });

  // ── the live area ─────────────────────────────────────────────────────────

  screen.region = () => {
    const w = width();
    const rows: string[] = [];
    for (const tool of tools.values()) {
      const took = Date.now() - tool.since;
      const label = `${toolLabel(tool.kind, tool.title)}${took >= 2000 ? c.faint(` ${seconds(took)}`) : ""}`;
      rows.push(...hang(label, `${c.accent(spin())} `, "  ", w));
    }
    if (block === "thought" && thought.trim()) {
      // The end of the thinking, as it is written.
      const lines = wrap(thought.replace(/\s+/gu, " ").trim(), w - 4).slice(-2);
      rows.push(...lines.map((line) => `  ${c.faint("│")} ${c.italic(c.muted(line))}`));
    }
    if (partial) {
      rows.push(
        ...markdown.preview(partial).map((row, i) => (i === 0 && firstRow ? marker(row) : row)),
      );
    }
    if (rows.length) rows.push("");
    if (working) {
      const doing = block === "thought" ? "Thinking…" : tools.size ? "Working…" : "Thinking…";
      rows.push(
        `${c.accent(spin())} ${shimmer(doing, frameNo)} ${c.faint(
          `${seconds(Date.now() - turnStarted)} · esc to interrupt`,
        )}`,
      );
    }

    // A menu takes the input's place while it is open.
    const open = choice;
    if (open) {
      const inside = w - 4;
      if (rows.length && rows[rows.length - 1] !== "") rows.push("");
      const body = [
        ...(open.detail?.length ? [...open.detail, ""] : []),
        ...hang(c.bold(open.question), "", "", inside),
        "",
        ...open.options.map((o, i) => {
          const selected = i === open.index;
          const label = (o.paint ?? ((t: string) => t))(o.label);
          const note = o.note ? c.faint(`  ${o.note}`) : "";
          return selected
            ? `${c.accent("❯")} ${c.accent(`${i + 1}.`)} ${c.bold(label)}${note}`
            : `  ${c.faint(`${i + 1}.`)} ${label}${note}`;
        }),
      ];
      rows.push(
        ...frame(body, w, {
          title: c.bold(c.accent(open.title)),
          foot: c.muted("↑↓ choose · enter · esc skips · or answer on the phone"),
          paint: c.accent,
        }),
      );
      return { rows, caret: null };
    }

    const inside = w - 4 - 2;
    const layout = editor.layout(inside);
    const box = layout.rows.map((row, i) => `${i === 0 ? c.accent("›") : " "} ${row}`);
    if (editor.empty) {
      box[0] = `${c.accent("›")} ${c.faint(`Message ${agentName}…  / for commands`)}`;
    }
    const top = rows.length;
    rows.push(...frame(box, w, { paint: c.faint }));

    // Commands matching what is typed, under the box, in place of the footer.
    const menu = commandMenu();
    if (menu.length) {
      const pad = Math.max(...menu.map(([name]) => textWidth(name))) + 2;
      menu.forEach(([name, what, mine], i) => {
        const selected = i === commandIndex % menu.length;
        const label = name.padEnd(pad);
        const note = mine ? "" : c.faint(`  ${agentName}`);
        rows.push(
          selected
            ? ` ${c.accent("❯")} ${c.bold(c.accent(label))}${c.text(what)}${note}`
            : `   ${c.muted(label)}${c.faint(what)}${note}`,
        );
      });
      return { rows, caret: { row: top + 1 + layout.row, column: 4 + layout.column } };
    }

    const left = [
      `${working ? c.violet(spin()) : c.green("●")} ${c.bold(agentName)}`,
      modelName() ? c.muted(modelName()) : "",
      usage && usage.size > 0
        ? `${meter(usage.used / usage.size)} ${c.muted(`${Math.round((usage.used / usage.size) * 100)}%`)}`
        : "",
    ]
      .filter(Boolean)
      .join(c.faint("  ·  "));
    const right = c.faint(working ? "esc interrupt · ctrl+c leave" : "↑ history · ctrl+d leave");
    // The hints go first when the row is short of room.
    rows.push(
      textWidth(left) + 2 + textWidth(right) <= w - 1
        ? ` ${spread(left, right, w - 1)}`
        : ` ${left}`,
    );
    return { rows, caret: { row: top + 1 + layout.row, column: 4 + layout.column } };
  };

  /** Commands matching what is typed: [name, what it does, Baya's own]. */
  const commandMenu = (): Array<[string, string, boolean]> => {
    const typed = editor.value;
    if (!typed.startsWith("/") || typed.includes(" ") || typed.includes("\n")) return [];
    return [
      ...COMMANDS.map(([n, w]): [string, string, boolean] => [n, w, true]),
      ...agentCommands
        .filter(([n]) => !COMMANDS.some(([own]) => own === n))
        .map(([n, w]): [string, string, boolean] => [n, w, false]),
    ]
      .filter(([n]) => n.startsWith(typed))
      .slice(0, 8);
  };

  /** Ends the reply line and the thought shown, before something else. */
  const settle = (next: string | null) => {
    if (block === next) return;
    const commit: string[] = [];
    if (partial) {
      commit.push(...reply(markdown.line(partial)));
      partial = "";
    }
    if (block === "agent") {
      commit.push(...reply(markdown.flush()));
      markdown.reset();
    }
    if (commit.length) screen.print(...commit);
    if (block === "thought" && thoughtSince) {
      const took = Date.now() - thoughtSince;
      screen.section("thought");
      screen.print(
        `${c.faint("◇")} ${c.italic(c.muted(took < 1000 ? "Thought briefly" : `Thought for ${seconds(took)}`))}`,
      );
      thoughtSince = 0;
      thought = "";
    }
    block = next;
  };

  /** A finished tool: its line for good, with what it did, shortly. */
  const finishTool = (kind: string, title: string, failed: boolean, raw: Json) => {
    turnTools++;
    screen.section("tool", true);
    const w = width();
    const out = hang(toolLabel(kind, title), `${failed ? c.red("●") : c.green("●")} `, "  ", w);
    const { text, diffs } = toolContent(raw);
    const lead = c.faint("  └ ");
    const under = "    ";
    const lines = text.split("\n").filter((line) => line.trim() !== "");
    const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
    if (diffs.length) {
      for (const diff of diffs) {
        const { rows, added, removed } = diffRows(diff.before, diff.after, {
          width: w,
          indent: under,
        });
        const what = [
          added ? `${c.green("+")}${count(added, "line", "lines")}` : "",
          removed ? `${c.red("-")}${count(removed, "line", "lines")}` : "",
        ]
          .filter(Boolean)
          .join(c.muted(", "));
        const file = diff.path.split(/[\\/]/u).pop() || "the file";
        out.push(
          `${lead}${c.muted(diff.before === "" ? `Created ${file} ` : `Updated ${file} `)}${what}`,
          ...rows,
        );
      }
    } else if (failed) {
      const shown = lines.slice(0, 3);
      for (const [i, line] of shown.entries()) {
        out.push(...hang(c.red(line.slice(0, 400)), i === 0 ? lead : under, under, w));
      }
      if (!shown.length) out.push(`${lead}${c.red("Failed")}`);
    } else if (kind === "read") {
      // What was read is in the agent's context; the count is what matters here.
      if (lines.length)
        out.push(`${lead}${c.muted(`Read ${count(lines.length, "line", "lines")}`)}`);
    } else if (kind === "search" || kind === "fetch") {
      if (lines.length) {
        out.push(
          `${lead}${c.muted(kind === "search" ? count(lines.length, "result", "results") : count(lines.length, "line", "lines"))}`,
        );
        for (const line of lines.slice(0, 3))
          out.push(...hang(c.faint(line.slice(0, 200)), under, under, w));
        if (lines.length > 3) out.push(`${under}${c.faint(`… +${lines.length - 3} more`)}`);
      }
    } else if (lines.length) {
      const tail = lines.slice(-5);
      for (const [i, line] of tail.entries()) {
        out.push(...hang(c.muted(line.slice(0, 400)), i === 0 ? lead : under, under, w));
      }
      if (lines.length > tail.length)
        out.push(
          `${under}${c.faint(`… +${count(lines.length - tail.length, "line", "lines")} above`)}`,
        );
    }
    screen.print(...out);
  };

  /** The end of a turn: a rule with how long it took and what it used. */
  const turnEnded = () => {
    if (!turnStarted) return;
    const used = turnTools ? ` · ${turnTools} tool${turnTools === 1 ? "" : "s"}` : "";
    const label = ` Worked for ${seconds(Date.now() - turnStarted)}${used} `;
    const side = Math.max(2, Math.floor((width() - textWidth(label)) / 2));
    screen.section("end");
    screen.print(c.faint(`${"─".repeat(side)}${label}${"─".repeat(side)}`), "");
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
        const w = width();
        return screen.print(
          ...hang(text, `${c.accent("›")} `, "  ", w - 1).map((row) => band(` ${row}`, w)),
        );
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
          thought = "";
        }
        thought = (thought + text).slice(-2000);
        return screen.draw();
      case "tool_call": {
        settle(null);
        const id = String(raw["toolCallId"]);
        const tool = {
          kind: String(raw["kind"] ?? ""),
          title: String(raw["title"] ?? "tool"),
          since: Date.now(),
        };
        const status = raw["status"];
        if (status === "completed" || status === "failed") {
          return finishTool(tool.kind, tool.title, status === "failed", raw);
        }
        tools.set(id, tool);
        return screen.draw();
      }
      case "tool_call_update": {
        const id = String(raw["toolCallId"]);
        const tool = tools.get(id) ?? {
          kind: String(raw["kind"] ?? ""),
          title: String(raw["title"] ?? "tool"),
          since: Date.now(),
        };
        if (typeof raw["title"] === "string") tool.title = raw["title"];
        const status = raw["status"];
        if (status === "completed" || status === "failed") {
          tools.delete(id);
          return finishTool(tool.kind, tool.title, status === "failed", raw);
        }
        if (tools.has(id)) tools.set(id, tool);
        return screen.draw();
      }
      case "plan": {
        settle(null);
        screen.section("plan");
        const entries = (Array.isArray(raw["entries"]) ? raw["entries"] : []).filter(isObject);
        const w = width();
        return screen.print(
          `${c.accent("●")} ${c.bold("Update plan")}`,
          ...entries.flatMap((entry, i) => {
            const status = entry["status"];
            const line = String(entry["content"] ?? "");
            const lead = i === 0 ? c.faint("  └ ") : "    ";
            if (status === "completed")
              return hang(c.strike(c.faint(line)), `${lead}${c.green("✓")} `, "      ", w);
            if (status === "in_progress")
              return hang(c.bold(line), `${lead}${c.accent("◐")} `, "      ", w);
            return hang(line, `${lead}${c.faint("○")} `, "      ", w);
          }),
        );
      }
      case "config_option_update":
        config = configOptions(raw["configOptions"]);
        return screen.draw();
      case "available_commands_update":
        agentCommands = (Array.isArray(raw["availableCommands"]) ? raw["availableCommands"] : [])
          .filter(isObject)
          .map((cmd): [string, string] => [
            `/${String(cmd["name"])}`,
            String(cmd["description"] ?? ""),
          ]);
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
        const running = tools.get(String(call["toolCallId"]));
        const options = (Array.isArray(params["options"]) ? params["options"] : [])
          .filter(isObject)
          .map((o) => ({
            optionId: String(o["optionId"]),
            name: String(o["name"]),
            kind: String(o["kind"] ?? ""),
          }));
        const title =
          typeof call["title"] === "string" ? call["title"] : running ? running.title : "";
        const kind = typeof call["kind"] === "string" ? call["kind"] : (running?.kind ?? "");
        const what = title ? toolLabel(kind, title) : c.bold("Go on");
        const { diffs } = toolContent(call);
        const preview = diffs.flatMap(
          (diff) => diffRows(diff.before, diff.after, { width: width() - 4, limit: 10 }).rows,
        );
        return new Promise((answer) => {
          const cancelled = { outcome: { outcome: "cancelled" } };
          asked.set(id, () => answer(cancelled));
          choice = {
            title: "Permission",
            detail: [what, ...preview],
            question: `Allow ${agentName} to do this?`,
            index: 0,
            options: options.map((o) => ({
              label: o.name,
              ...(o.kind.startsWith("reject")
                ? { paint: c.red }
                : o.kind === "allow_always"
                  ? { note: "this session" }
                  : {}),
            })),
            pick: (index) => {
              asked.delete(id);
              const picked = index === null ? undefined : options[index];
              answer(
                picked
                  ? { outcome: { outcome: "selected", optionId: picked.optionId } }
                  : cancelled,
              );
              const verdict = picked
                ? picked.kind.startsWith("reject")
                  ? c.red(picked.name)
                  : c.green(picked.name)
                : c.muted("Skipped");
              screen.section("permission");
              screen.print(
                `${c.accent("●")} ${c.bold("Permission")} ${c.muted("·")} ${what}`,
                `${c.faint("  └ ")}${verdict}`,
              );
            },
          };
          screen.draw();
        });
      }
      if (method === "elicitation/create") {
        screen.print(
          `${c.accent("●")} ${c.muted("The agent asks for details. Answer it on the phone.")}`,
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
        screen.print(`${c.faint("  └ ")}${c.muted("Answered on the phone")}`, "");
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
  const loaded = await peer.request<Json>("session/load", {
    sessionId,
    cwd: session.cwd,
    mcpServers: [],
  });
  replaying = false;
  config = configOptions(loaded["configOptions"]);
  settle(null);
  tools.clear();

  // The welcome card goes last, so it is what one sees over the input.
  const card = (() => {
    const w = Math.min(width(), 78);
    const rows = [
      `${gradient("◆ Baya", [232, 180, 74], [214, 120, 170])}  ${c.faint("live with your phone")}`,
      "",
      ...hang(c.bold(session.title || folder(session.cwd)), "  ", "  ", w - 4),
      `  ${c.muted([agentName, modelName()].filter(Boolean).join(" · "))}`,
      `  ${c.muted(folder(session.cwd))}`,
      "",
      `  ${c.faint("/help for commands · esc interrupts · ctrl+d leaves")}`,
    ];
    return frame(rows, w, { paint: c.accent });
  })();
  screen.section("card");
  screen.print(...card, "");
  working = session.working;
  if (working) turnStarted = Date.now();

  const ticker = setInterval(() => {
    frameNo++;
    if (working || tools.size) screen.draw();
  }, 80);
  const resize = () => screen.draw();
  process.stdout.on("resize", resize);

  await new Promise<void>((resolve) => {
    let closed = false;
    let lastInterrupt = 0;
    const quit = () => {
      if (closed) return;
      closed = true;
      clearInterval(ticker);
      process.stdout.off("resize", resize);
      settle(null);
      screen.close();
      if (isTty()) {
        process.stdout.write(`${ESC}?2004l`);
        if (process.stdin.isTTY) process.stdin.setRawMode(false);
      }
      // Leave no handle behind: the socket goes now and stdin lets go.
      socket.destroy();
      process.stdin.pause();
      process.stdin.unref?.();
      resolve();
    };
    const interrupt = () => {
      peer.notify("session/cancel", { sessionId });
      screen.section("interrupt");
      screen.print(`${c.faint("  └ ")}${c.muted("Interrupted")}`);
    };
    const chooseModel = () => {
      const option = model();
      if (!option || option.options.length === 0) {
        return screen.print(
          `${c.faint("  └ ")}${c.muted("This agent has no models to choose from.")}`,
        );
      }
      const current = option.options.findIndex((o) => o.value === option.currentValue);
      choice = {
        title: "Model",
        question: `Which model should ${agentName} use?`,
        index: Math.max(0, current),
        options: option.options.map((o) => ({
          label: o.name,
          ...(o.value === option.currentValue ? { note: "current" } : {}),
        })),
        pick: (index) => {
          const picked = index === null ? undefined : option.options[index];
          if (!picked || picked.value === option.currentValue) return screen.draw();
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
                screen.section("model");
                screen.print(`${c.accent("●")} ${c.bold("Model")} ${c.muted(picked.name)}`);
              },
              (error: Error) => screen.print(`${c.red("●")} ${error.message}`),
            );
        },
      };
      screen.draw();
    };
    const help = () => {
      screen.section("help");
      screen.print(
        ...frame(
          [
            c.bold("Commands"),
            ...COMMANDS.map(([name, what]) => `  ${c.accent(name.padEnd(8))} ${c.muted(what)}`),
            "",
            c.bold("Keys"),
            `  ${c.accent("enter".padEnd(8))} ${c.muted("send — the phone sees it too")}`,
            `  ${c.accent("ctrl+j".padEnd(8))} ${c.muted("new line")}`,
            `  ${c.accent("esc".padEnd(8))} ${c.muted("interrupt the agent")}`,
            `  ${c.accent("↑ ↓".padEnd(8))} ${c.muted("earlier messages")}`,
            `  ${c.accent("ctrl+d".padEnd(8))} ${c.muted("leave")}`,
          ],
          Math.min(width(), 72),
          { paint: c.faint },
        ),
      );
    };
    const send = (text: string) => {
      const trimmed = text.trim();
      if (!trimmed) return screen.draw();
      switch (trimmed) {
        case "/quit":
        case "/exit":
          return quit();
        case "/help":
          return help();
        case "/stop":
          return working ? interrupt() : screen.draw();
        case "/clear":
          process.stdout.write(`${ESC}2J${ESC}3J${ESC}H`);
          return screen.print(...card, "");
        case "/model":
          return chooseModel();
      }
      if (trimmed === "/rename" || trimmed.startsWith("/rename ")) {
        const title = trimmed.slice("/rename".length).trim();
        if (!title) {
          return screen.print(`${c.faint("  └ ")}${c.muted("Type a name after /rename.")}`);
        }
        peer.request("_baya/rename", { sessionId, title }).then(
          () => {
            screen.section("rename");
            screen.print(`${c.accent("●")} ${c.bold("Renamed")} ${c.muted(title)}`);
          },
          (error: Error) => screen.print(`${c.red("●")} ${error.message}`),
        );
        return screen.draw();
      }
      peer
        .request("session/prompt", {
          sessionId,
          prompt: [{ type: "text", text: trimmed }],
          _meta: { baya: { messageId: randomUUID() } },
        })
        .then(
          () => {
            settle(null);
            screen.draw();
          },
          (error: Error) => screen.print(`${c.red("●")} ${error.message}`),
        );
      screen.draw();
    };

    socket.on("close", () => {
      if (closed) return;
      screen.print(`${c.faint("  └ ")}${c.muted("Baya closed the connection.")}`);
      quit();
    });

    if (!isTty() || !process.stdin.isTTY) {
      // Piped input: one message per line.
      const rl = createInterface({ input: process.stdin });
      rl.on("line", (line) => {
        if (choice) {
          const open = choice;
          choice = null;
          const n = Number(line.trim());
          open.pick(Number.isInteger(n) && n >= 1 && n <= open.options.length ? n - 1 : null);
          return;
        }
        send(line);
      });
      rl.on("close", quit);
      screen.draw();
      return;
    }

    emitKeypressEvents(process.stdin);
    process.stdin.setRawMode(true);
    process.stdout.write(`${ESC}?2004h`);
    let pasting = false;
    process.stdin.on(
      "keypress",
      (
        str: string | undefined,
        key: { name?: string; ctrl?: boolean; meta?: boolean; sequence?: string } = {},
      ) => {
        if (closed) return;
        const name = key.name;
        if (name === "paste-start") {
          pasting = true;
          return;
        }
        if (name === "paste-end") {
          pasting = false;
          return screen.draw();
        }
        if (pasting) {
          editor.insert(name === "return" || name === "enter" ? "\n" : (str ?? ""));
          return;
        }

        const open = choice;
        if (open) {
          if (name === "up")
            open.index = (open.index + open.options.length - 1) % open.options.length;
          else if (name === "down" || name === "tab")
            open.index = (open.index + 1) % open.options.length;
          else if (name === "return" || name === "enter") {
            choice = null;
            open.pick(open.index);
          } else if (name === "escape" || (key.ctrl && name === "c")) {
            choice = null;
            open.pick(null);
          } else if (str && /^[1-9]$/u.test(str) && Number(str) <= open.options.length) {
            choice = null;
            open.pick(Number(str) - 1);
          }
          return screen.draw();
        }

        const menu = commandMenu();
        if (key.ctrl && name === "c") {
          const now = Date.now();
          if (!editor.empty) editor.take();
          else if (working && now - lastInterrupt > 1500) {
            lastInterrupt = now;
            interrupt();
          } else return quit();
          return screen.draw();
        }
        if (key.ctrl && name === "d") {
          if (editor.empty) return quit();
          editor.delete();
          return screen.draw();
        }
        if (name === "escape") {
          if (working) interrupt();
          return screen.draw();
        }
        if ((key.ctrl && name === "j") || (name === "return" && key.meta)) editor.insert("\n");
        else if (name === "return" || name === "enter") {
          // Enter on a part of a command runs the one highlighted.
          if (menu.length && !menu.some(([n]) => n === editor.value)) {
            editor.set(menu[commandIndex % menu.length]![0]);
          }
          commandIndex = 0;
          return send(editor.take());
        } else if (name === "backspace") editor.backspace();
        else if (name === "delete") editor.delete();
        else if (name === "left") editor.left();
        else if (name === "right") editor.right();
        else if (name === "home" || (key.ctrl && name === "a")) editor.home();
        else if (name === "end" || (key.ctrl && name === "e")) editor.end();
        else if (key.ctrl && name === "u") editor.killBefore();
        else if (key.ctrl && name === "k") editor.killAfter();
        else if (key.ctrl && name === "w") editor.killWord();
        else if (key.ctrl && name === "l") {
          process.stdout.write(`${ESC}2J${ESC}H`);
        } else if (menu.length && (name === "up" || name === "down")) {
          commandIndex = (commandIndex + (name === "up" ? menu.length - 1 : 1)) % menu.length;
          return screen.draw();
        } else if (name === "up" && editor.onFirstLine) editor.previous();
        else if (name === "down" && editor.onLastLine) editor.next();
        else if (name === "tab" && menu.length) {
          editor.set(`${menu[commandIndex % menu.length]![0]} `);
        } else if (str && !key.ctrl && !key.meta) editor.insert(str);
        // What is typed changed: the menu starts at its top again.
        commandIndex = 0;
        screen.draw();
      },
    );
    screen.draw();
  });
}
