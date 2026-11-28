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
/** The most history one read returns. */
const MAX_READ = 10_000;
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

/** One attached terminal on the phone. */
interface Stream {
  terminal: string;
  channel: number;
  offset: number;
  /** Watching only: the computer keeps its size. */
  observe: boolean;
  /** Its size as hc last told an observer. */
  size?: { cols: number; rows: number };
  /** An observer's attach for keys, opened at the first key. */
  typing?: { channel: number; queued: Buffer[] } | undefined;
  /** The last byte or size handed to the phone. */
  sent: Promise<void>;
}

function sizeFrame(cols: number, rows: number): Buffer {
  const payload = Buffer.alloc(4);
  payload.writeUInt16LE(cols, 0);
  payload.writeUInt16LE(rows, 2);
  return payload;
}

export class PhoneTerminals {
  private readonly phone: TerminalPhone;
  private readonly core: HerdrCore;
  /** The phone's stream ids → hc channels, with the bytes sent so far. */
  private readonly streams = new Map<number, Stream>();

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
      // A shell started from the phone, or a session's agent, survives
      // losing its program: the phone comes back to a shell in the same
      // folder (an agent that exits at once, say a new session with
      // nothing to resume yet, still leaves a terminal to open).
      keep: (!line && argv.length === 0) || params["keep"] === true,
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
    // Watching it as it is (a pane shown on the computer too): its size
    // stays the computer's, and the phone is told each new size.
    const observe = params["observe"] === true;
    const entry: Stream = { terminal, channel: -1, offset: 0, observe, sent: Promise.resolve() };
    this.streams.set(stream, entry);
    // Bytes and sizes reach the phone in the order hc sent them.
    const inOrder = (send: () => Promise<void> | void) => {
      entry.sent = entry.sent.then(send).catch(() => {});
      return entry.sent;
    };
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
          ...(observe ? { observe: true, resize_notifications: true } : {}),
          ...(isDisplay(params["display"]) ? { display: params["display"] } : {}),
        },
        {
          data: (bytes) =>
            inOrder(() => {
              const offset = entry.offset;
              entry.offset += bytes.length;
              return this.phone.sendData(stream, offset, bytes, SOCKET_BUFFER);
            }),
          resize: (cols, rows) => {
            entry.size = { cols, rows };
            if (entry.typing && entry.typing.channel >= 0) {
              this.core.send(entry.typing.channel, FRAME.resize, sizeFrame(cols, rows));
            }
            void inOrder(() => this.phone.notify("_baya/terminal_size", { stream, cols, rows }));
          },
          close: (reason) => {
            if (this.streams.get(stream) !== entry) return;
            this.streams.delete(stream);
            this.endTyping(entry);
            this.phone.notify("_baya/terminal_closed", { stream, ...(reason ?? {}) });
          },
        },
      );
    } catch (error) {
      if (this.streams.get(stream) === entry) this.streams.delete(stream);
      throw error;
    }
    entry.channel = result["channel"] as number;
    const facts = result["terminal"] as Json | undefined;
    const cols = size(facts?.["cols"], 65535);
    const rows = size(facts?.["rows"], 65535);
    if (!entry.size && cols && rows) entry.size = { cols, rows };
    // Detached while the reply was on its way.
    if (this.streams.get(stream) !== entry) this.core.closeChannel(entry.channel);
    return { terminal: result["terminal"] };
  }

  detach(stream: number): void {
    const entry = this.streams.get(stream);
    if (!entry) return;
    this.streams.delete(stream);
    if (entry.channel >= 0) this.core.closeChannel(entry.channel);
    this.endTyping(entry);
  }

  input(stream: unknown, data: unknown): void {
    const entry = typeof stream === "number" ? this.streams.get(stream) : undefined;
    if (!entry || entry.channel < 0 || typeof data !== "string" || !data) return;
    const bytes = Buffer.from(data, "utf8");
    if (!entry.observe) {
      this.core.send(entry.channel, FRAME.data, bytes);
      return;
    }
    // An observer can't type: keys go through a second attach that asks
    // for the size the terminal already has, so typing never resizes it.
    entry.typing ??= { channel: -1, queued: [] };
    const typing = entry.typing;
    if (typing.channel >= 0) {
      this.core.send(typing.channel, FRAME.data, bytes);
      return;
    }
    typing.queued.push(bytes);
    if (typing.queued.length > 1 || !entry.size) return;
    void this.core
      .open(
        "terminal.attach",
        {
          terminal: entry.terminal,
          cols: entry.size.cols,
          rows: entry.size.rows,
          history: 0,
        },
        // Its paint is the observer's too: dropped.
        { data: () => {}, close: () => {} },
      )
      .then((opened) => {
        const channel = opened["channel"] as number;
        if (entry.typing !== typing) {
          this.core.closeChannel(channel);
          return;
        }
        typing.channel = channel;
        if (entry.size) {
          this.core.send(channel, FRAME.resize, sizeFrame(entry.size.cols, entry.size.rows));
        }
        for (const queued of typing.queued) this.core.send(channel, FRAME.data, queued);
        typing.queued = [];
      })
      .catch(() => {
        if (entry.typing === typing) entry.typing = undefined;
      });
  }

  resize(stream: unknown, cols: unknown, rows: unknown): void {
    const entry = typeof stream === "number" ? this.streams.get(stream) : undefined;
    const width = size(cols, 65535);
    const height = size(rows, 65535);
    // An observer leaves the size to the computer.
    if (!entry || entry.observe || entry.channel < 0 || !width || !height) return;
    this.core.send(entry.channel, FRAME.resize, sizeFrame(width, height));
  }

  private endTyping(entry: Stream): void {
    const typing = entry.typing;
    entry.typing = undefined;
    if (typing && typing.channel >= 0) this.core.closeChannel(typing.channel);
  }

  /**
   * Its screen and up to [lines] of history as plain text, for reading
   * further back than the phone was sent on attach.
   */
  read(terminal: unknown, lines: unknown): Promise<Json> {
    return this.core.call("terminal.read", {
      terminal: String(terminal),
      lines: size(lines, MAX_READ) ?? MAX_READ,
    });
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
