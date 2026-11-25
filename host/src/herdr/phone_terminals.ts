/**
 * herdr-core's terminals, for one phone: list them, start a shell or an
 * agent in one, and attach to watch and type.
 *
 * An attached terminal's bytes travel to the phone as data frames on a
 * stream the phone picked, as downloads do; keys and sizes come back as
 * notifications. hc gets credit for bytes as the phone's link takes them,
 * so a slow link means a fresh paint later, not a pile-up.
 */
import { homedir } from "node:os";
import { FRAME, type HerdrCore, HerdrError, herdr } from "./core.ts";

type Json = Record<string, unknown>;

export interface TerminalPhone {
  notify(method: string, params: Json): void;
  sendData(stream: number, offset: number, bytes: Buffer, buffer?: number): Promise<void>;
}

/**
 * Scrollback sent above the screen when a phone attaches: a few screens, so
 * the first paint is quick; the phone parses every byte of it.
 */
const HISTORY = 300;
/**
 * Terminal bytes the phone's socket may hold before hc is told to wait. Kept
 * small so a keystroke's echo never queues behind seconds of output: past
 * it hc falls behind, and a viewer far enough behind gets a fresh paint of
 * the screen rather than the backlog.
 */
const SOCKET_BUFFER = 256 * 1024;
/** Events that land within this long reach phones as one change. */
const SETTLE_MS = 150;

const size = (value: unknown, max: number): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= max ? value : null;

/** Tells phones when any terminal changed, from one `events.subscribe`. */
class TerminalWatch {
  private readonly phones = new Set<TerminalPhone>();
  private channel: number | null = null;
  private starting = false;
  private timer: NodeJS.Timeout | undefined;
  private retry: NodeJS.Timeout | undefined;
  private readonly core: HerdrCore;

  constructor(core: HerdrCore) {
    this.core = core;
  }

  add(phone: TerminalPhone): void {
    this.phones.add(phone);
    void this.start();
  }

  remove(phone: TerminalPhone): void {
    this.phones.delete(phone);
    if (this.phones.size > 0 || this.channel === null) return;
    this.core.closeChannel(this.channel);
    this.channel = null;
  }

  private async start(): Promise<void> {
    if (this.channel !== null || this.starting || this.phones.size === 0) return;
    this.starting = true;
    let partial = "";
    try {
      const result = await this.core.open(
        "events.subscribe",
        {},
        {
          data: (bytes) => {
            partial += bytes.toString("utf8");
            const lines = partial.split("\n");
            partial = lines.pop() ?? "";
            if (
              lines.some((line) => line.includes('"method":"event"') || line.includes('"missed"'))
            ) {
              this.changed();
            }
          },
          close: () => {
            this.channel = null;
            if (this.phones.size === 0) return;
            this.changed();
            clearTimeout(this.retry);
            this.retry = setTimeout(() => void this.start(), 2000);
          },
        },
      );
      this.channel = result["channel"] as number;
    } catch {
      clearTimeout(this.retry);
      if (this.phones.size > 0) this.retry = setTimeout(() => void this.start(), 5000);
    } finally {
      this.starting = false;
    }
  }

  private changed(): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      for (const phone of this.phones) phone.notify("_baya/terminals_changed", {});
    }, SETTLE_MS);
  }
}

const watch = new TerminalWatch(herdr);

export class PhoneTerminals {
  private readonly phone: TerminalPhone;
  private readonly core: HerdrCore;
  /** The phone's stream ids → hc channels, with the bytes sent so far. */
  private readonly streams = new Map<number, { channel: number; offset: number }>();

  constructor(phone: TerminalPhone, core: HerdrCore = herdr) {
    this.phone = phone;
    this.core = core;
  }

  async list(): Promise<Json> {
    if (!(await this.core.available())) return { available: false, terminals: [] };
    watch.add(this.phone);
    const result = await this.core.call("terminal.list", {});
    return { available: true, terminals: result["terminals"] ?? [] };
  }

  /** A new terminal: the computer's shell, or [argv] or a [line] (an agent, a server). */
  async run(params: Json): Promise<Json> {
    const argv = Array.isArray(params["argv"])
      ? params["argv"].filter((part): part is string => typeof part === "string" && part !== "")
      : [];
    const cols = size(params["cols"], 1000);
    const rows = size(params["rows"], 1000);
    // Home, not wherever hc's core happened to start.
    const cwd = typeof params["cwd"] === "string" && params["cwd"] ? params["cwd"] : homedir();
    // A line as typed (`claude --continue`), run by the computer's shell.
    const line = typeof params["line"] === "string" ? params["line"].trim() : "";
    return this.core.call("terminal.run", {
      ...(line ? { line } : argv.length ? { argv } : {}),
      cwd,
      ...(cols && rows ? { size: { cols, rows } } : {}),
      // A shell started from the phone survives losing its program: the
      // phone comes back to a shell in the same folder.
      keep: !line && argv.length === 0,
      no_parent: true,
      labels: {
        "baya.from": "phone",
        // A session's own terminal, found again by its label.
        ...(typeof params["session"] === "string" && params["session"]
          ? { "baya.session": params["session"] }
          : {}),
      },
    });
  }

  async attach(params: Json): Promise<Json> {
    const terminal = params["terminal"];
    const stream = params["stream"];
    if (typeof terminal !== "string" || typeof stream !== "number") {
      throw new HerdrError("A terminal and a stream are required.");
    }
    this.detach(stream);
    const entry = { channel: -1, offset: 0 };
    this.streams.set(stream, entry);
    let result: Json;
    try {
      result = await this.core.open(
        "terminal.attach",
        {
          terminal,
          cols: size(params["cols"], 1000) ?? 80,
          rows: size(params["rows"], 1000) ?? 24,
          history: HISTORY,
          resumed: params["resumed"] === true,
          ...(isDisplay(params["display"]) ? { display: params["display"] } : {}),
        },
        {
          data: async (bytes) => {
            const offset = entry.offset;
            entry.offset += bytes.length;
            await this.phone.sendData(stream, offset, bytes, SOCKET_BUFFER);
          },
          close: (reason) => {
            if (this.streams.get(stream) !== entry) return;
            this.streams.delete(stream);
            this.phone.notify("_baya/terminal_closed", { stream, ...(reason ?? {}) });
          },
        },
      );
    } catch (error) {
      if (this.streams.get(stream) === entry) this.streams.delete(stream);
      throw error;
    }
    entry.channel = result["channel"] as number;
    // Detached while the reply was on its way.
    if (this.streams.get(stream) !== entry) this.core.closeChannel(entry.channel);
    return { terminal: result["terminal"] };
  }

  detach(stream: number): void {
    const entry = this.streams.get(stream);
    if (!entry) return;
    this.streams.delete(stream);
    if (entry.channel >= 0) this.core.closeChannel(entry.channel);
  }

  input(stream: unknown, data: unknown): void {
    const entry = typeof stream === "number" ? this.streams.get(stream) : undefined;
    if (!entry || entry.channel < 0 || typeof data !== "string" || !data) return;
    this.core.send(entry.channel, FRAME.data, Buffer.from(data, "utf8"));
  }

  resize(stream: unknown, cols: unknown, rows: unknown): void {
    const entry = typeof stream === "number" ? this.streams.get(stream) : undefined;
    const width = size(cols, 65535);
    const height = size(rows, 65535);
    if (!entry || entry.channel < 0 || !width || !height) return;
    const payload = Buffer.alloc(4);
    payload.writeUInt16LE(width, 0);
    payload.writeUInt16LE(height, 2);
    this.core.send(entry.channel, FRAME.resize, payload);
  }

  kill(terminal: unknown): Promise<Json> {
    return this.core.call("terminal.kill", { terminal: String(terminal) });
  }

  remove(terminal: unknown): Promise<Json> {
    return this.core.call("terminal.rm", { terminal: String(terminal) });
  }

  /** The phone went away: its streams end, its terminals keep running. */
  close(): void {
    for (const stream of [...this.streams.keys()]) this.detach(stream);
    watch.remove(this.phone);
  }
}

function isDisplay(value: unknown): value is Json {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const { bg, fg } = value as Json;
  const color = (c: unknown) =>
    c === undefined || (typeof c === "string" && /^#[0-9a-f]{6}$/iu.test(c));
  return color(bg) && color(fg);
}
