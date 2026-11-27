/**
 * A client of herdr-core (`hc`), which keeps this computer's terminals alive
 * whoever watches them: agents in their own TUIs, shells, dev servers.
 *
 * Baya speaks hc's framed protocol through `hc connect` (stdin/stdout), so
 * hc finds its own socket or named pipe and starts its core when needed.
 * Every frame is `[channel u32 LE][kind u8][len u32 LE][payload]`; channel 0
 * carries JSON-RPC, others carry a terminal's bytes or a stream of events.
 * A terminal stream is flow-controlled with credit: Baya grants it as the
 * phone takes the bytes, and a phone that falls far behind gets a fresh
 * paint of the screen instead of the backlog.
 */
import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { findExecutable } from "../workspace/directories.ts";

export const FRAME = { data: 0, credit: 1, close: 2, resize: 3, focus: 4, facts: 5 } as const;

const HEADER = 9;
const MAX_PAYLOAD = 16 * 1024 * 1024;

export class HerdrError extends Error {
  readonly kind: string | undefined;
  constructor(message: string, kind?: string) {
    super(message);
    this.kind = kind;
  }
}

/** What a stream's channel receives. */
export interface ChannelHandler {
  /** Bytes; resolve once they are passed on, which grants hc more credit. */
  data(bytes: Buffer): Promise<void> | void;
  /** The channel ended; [reason] is hc's JSON reason, if it gave one. */
  close(reason: Record<string, unknown> | null): void;
  /** The terminal's new size, before the paint at that size (observers that asked). */
  resize?(cols: number, rows: number): void;
}

type Json = Record<string, unknown>;

export function encodeFrame(channel: number, kind: number, payload: Buffer): Buffer {
  const header = Buffer.alloc(HEADER);
  header.writeUInt32LE(channel, 0);
  header[4] = kind;
  header.writeUInt32LE(payload.length, 5);
  return Buffer.concat([header, payload]);
}

/** Splits a byte stream into frames, keeping a partial one for later. */
export class FrameReader {
  private buffer: Buffer = Buffer.alloc(0);

  push(chunk: Buffer): Array<{ channel: number; kind: number; payload: Buffer }> {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    const frames: Array<{ channel: number; kind: number; payload: Buffer }> = [];
    while (this.buffer.length >= HEADER) {
      const length = this.buffer.readUInt32LE(5);
      if (length > MAX_PAYLOAD) throw new HerdrError("herdr-core sent an oversized frame.");
      if (this.buffer.length < HEADER + length) break;
      frames.push({
        channel: this.buffer.readUInt32LE(0),
        kind: this.buffer[4]!,
        payload: Buffer.from(this.buffer.subarray(HEADER, HEADER + length)),
      });
      this.buffer = this.buffer.subarray(HEADER + length);
    }
    return frames;
  }
}

/** One `hc connect`, started on first use and again after it ends. */
export class HerdrCore {
  private child: ChildProcessByStdio<Writable, Readable, null> | null = null;
  private connecting: Promise<void> | null = null;
  private nextId = 1;
  private readonly pending = new Map<
    number,
    { resolve: (value: Json) => void; reject: (error: Error) => void }
  >();
  private readonly channels = new Map<number, ChannelHandler>();
  /** Frames for a channel whose handler is not set yet (its reply is in flight). */
  private readonly early = new Map<number, Array<{ kind: number; payload: Buffer }>>();
  private readonly lostListeners = new Set<() => void>();
  /** `hc connect`, or a stand-in in tests; null when hc is not installed. */
  private readonly command: () => Promise<string[] | null>;

  constructor(
    command: () => Promise<string[] | null> = async () => {
      const hc = await findExecutable("hc");
      return hc ? [hc, "connect"] : null;
    },
  ) {
    this.command = command;
  }

  /** Whether hc is installed here. */
  async available(): Promise<boolean> {
    return (await this.command()) !== null;
  }

  /** Fires when the connection to hc ends; streams and subscriptions are gone. */
  onLost(listener: () => void): () => void {
    this.lostListeners.add(listener);
    return () => this.lostListeners.delete(listener);
  }

  async call(method: string, params: Json = {}): Promise<Json> {
    await this.connect();
    return this.request(method, params);
  }

  /**
   * Calls a method that opens a channel (`terminal.attach`,
   * `events.subscribe`), giving its frames to [handler].
   */
  async open(method: string, params: Json, handler: ChannelHandler): Promise<Json> {
    const result = await this.call(method, params);
    const channel = result["channel"];
    if (typeof channel !== "number") throw new HerdrError(`${method} opened no channel.`);
    this.channels.set(channel, handler);
    for (const frame of this.early.get(channel) ?? [])
      this.deliver(channel, frame.kind, frame.payload);
    this.early.delete(channel);
    return result;
  }

  send(channel: number, kind: number, payload: Buffer = Buffer.alloc(0)): void {
    const stdin = this.child?.stdin;
    if (!stdin || stdin.destroyed) return;
    stdin.write(encodeFrame(channel, kind, payload));
  }

  /** Ends a stream from this side; hc answers with an empty CLOSE. */
  closeChannel(channel: number): void {
    if (!this.channels.delete(channel)) return;
    this.send(channel, FRAME.close);
  }

  dispose(): void {
    this.child?.kill();
    this.child = null;
  }

  private connect(): Promise<void> {
    if (this.child) return Promise.resolve();
    this.connecting ??= this.start().finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  private async start(): Promise<void> {
    const command = await this.command();
    if (!command) {
      throw new HerdrError(
        "herdr-core is not installed on this computer: https://github.com/herdrdev/herdr-core",
        "not_installed",
      );
    }
    const [file, ...args] = command;
    const child = spawn(file!, args, { stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
    const reader = new FrameReader();
    let framed = false;
    let line: Buffer = Buffer.alloc(0);
    const hello = new Promise<void>((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", () => reject(new HerdrError("herdr-core ended before it answered.")));
      child.stdout.on("data", (chunk: Buffer) => {
        try {
          if (!framed) {
            // The reply to `hello` is the last plain line; frames follow.
            line = Buffer.concat([line, chunk]);
            const newline = line.indexOf(10);
            if (newline < 0) return;
            const reply = JSON.parse(line.subarray(0, newline).toString("utf8")) as Json;
            framed = true;
            if (reply["error"]) {
              reject(new HerdrError(errorText(reply["error"])));
              return;
            }
            resolve();
            chunk = line.subarray(newline + 1);
            if (chunk.length === 0) return;
          }
          for (const frame of reader.push(chunk))
            this.frame(frame.channel, frame.kind, frame.payload);
        } catch (error) {
          reject(error as Error);
          child.kill();
        }
      });
    });
    child.stdin.on("error", () => {});
    child.on("exit", () => this.lost(child));
    child.stdin.write(
      `${JSON.stringify({ jsonrpc: "2.0", id: 0, method: "hello", params: { framed: true, generation: 1 } })}\n`,
    );
    this.child = child;
    try {
      await hello;
    } catch (error) {
      this.lost(child);
      throw error;
    }
  }

  private request(method: string, params: Json): Promise<Json> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.send(0, FRAME.data, Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, method, params })));
    });
  }

  private frame(channel: number, kind: number, payload: Buffer): void {
    if (channel === 0) {
      if (kind !== FRAME.data) return;
      const message = JSON.parse(payload.toString("utf8")) as Json;
      const waiting =
        typeof message["id"] === "number" ? this.pending.get(message["id"]) : undefined;
      if (!waiting) return;
      this.pending.delete(message["id"] as number);
      if (message["error"]) {
        const error = message["error"] as Json;
        const data = error["data"] as Json | undefined;
        waiting.reject(
          new HerdrError(
            errorText(error),
            typeof data?.["kind"] === "string" ? data["kind"] : undefined,
          ),
        );
      } else {
        waiting.resolve((message["result"] ?? {}) as Json);
      }
      return;
    }
    if (!this.channels.has(channel)) {
      const queue = this.early.get(channel) ?? [];
      queue.push({ kind, payload });
      this.early.set(channel, queue);
      return;
    }
    this.deliver(channel, kind, payload);
  }

  private deliver(channel: number, kind: number, payload: Buffer): void {
    const handler = this.channels.get(channel);
    if (!handler) return;
    if (kind === FRAME.data) {
      const size = payload.length;
      void Promise.resolve(handler.data(payload))
        .catch(() => {})
        .then(() => {
          if (!this.channels.has(channel)) return;
          const credit = Buffer.alloc(4);
          credit.writeUInt32LE(size);
          this.send(channel, FRAME.credit, credit);
        });
    } else if (kind === FRAME.resize && payload.length >= 4) {
      handler.resize?.(payload.readUInt16LE(0), payload.readUInt16LE(2));
    } else if (kind === FRAME.close) {
      this.channels.delete(channel);
      let reason: Json | null = null;
      try {
        reason = payload.length ? (JSON.parse(payload.toString("utf8")) as Json) : null;
      } catch {
        reason = null;
      }
      handler.close(reason);
    }
  }

  private lost(child: ChildProcessByStdio<Writable, Readable, null>): void {
    if (this.child !== child) return;
    this.child = null;
    const error = new HerdrError("The connection to herdr-core ended.", "core_lost");
    for (const waiting of this.pending.values()) waiting.reject(error);
    this.pending.clear();
    const channels = [...this.channels.values()];
    this.channels.clear();
    this.early.clear();
    for (const handler of channels) handler.close({ reason: "core_lost" });
    for (const listener of this.lostListeners) listener();
  }
}

function errorText(error: unknown): string {
  if (error && typeof error === "object") {
    const { message, data } = error as Json;
    const hint = data && typeof data === "object" ? (data as Json)["hint"] : undefined;
    return [message, hint].filter((part) => typeof part === "string" && part).join(" — ");
  }
  return String(error);
}

/** The host's one connection to hc. */
export const herdr = new HerdrCore();
