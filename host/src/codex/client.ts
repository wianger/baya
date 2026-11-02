import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { spawnPlan } from "../process/spawn.ts";
import { packageVersion } from "../runtime/version.ts";

export type JsonObject = Record<string, unknown>;
export type RpcId = number | string;
export interface CodexServerRequest {
  id: RpcId;
  method: string;
  params: JsonObject;
}
export interface CodexClientEvents {
  notification: [method: string, params: JsonObject];
  request: [request: CodexServerRequest];
  closed: [error: Error];
}

export function object(value: unknown): JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : {};
}

/** Official app-server JSON-RPC over a private child-process stdio pipe. */
export class CodexClient extends EventEmitter<CodexClientEvents> {
  private child: ChildProcessWithoutNullStreams | null = null;
  private sequence = 0;
  private buffer = "";
  private closing = false;
  private readonly pending = new Map<
    RpcId,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();

  private readonly cwd: string;
  private readonly executable: string;

  constructor(cwd: string, executable = "codex") {
    super();
    this.cwd = cwd;
    this.executable = executable;
  }

  async start(): Promise<void> {
    if (this.child) return;
    const plan = spawnPlan(this.executable, ["app-server", "--listen", "stdio://"]);
    this.closing = false;
    const child = spawn(plan.command, plan.prefixArgs, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
      env: { ...process.env },
    });
    this.child = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.receive(chunk));
    // Keep credentials and startup diagnostics on the computer, not in chat.
    child.stderr.on("data", (chunk: Buffer) => process.stderr.write(chunk));
    child.on("error", (error) => this.lost(error));
    child.on("exit", (code) =>
      this.lost(new Error(`Codex app-server stopped (${code ?? "signal"}).`)),
    );
    await this.request("initialize", {
      clientInfo: { name: "baya", title: "Baya", version: packageVersion() },
      capabilities: { experimentalApi: true },
    });
    this.write({ method: "initialized", params: {} });
  }

  request(method: string, params: JsonObject = {}, timeoutMs = 60_000): Promise<unknown> {
    if (!this.child) return Promise.reject(new Error("Codex is not connected."));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex did not answer ${method} in time.`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.write({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("Could not send to Codex."));
      }
    });
  }

  respond(id: RpcId, result: unknown): void {
    this.write({ id, result });
  }

  rejectRequest(id: RpcId, message: string): void {
    this.write({ id, error: { code: -32601, message } });
  }

  close(): void {
    this.closing = true;
    const child = this.child;
    this.child = null;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Codex connection closed."));
    }
    this.pending.clear();
    if (child) {
      child.stdin.end();
      child.kill("SIGTERM");
    }
  }

  private write(message: JsonObject): void {
    if (!this.child?.stdin.writable) throw new Error("Codex is not connected.");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private receive(chunk: string): void {
    this.buffer += chunk;
    // A peer can emit long tool outputs, but an unterminated frame is bounded.
    if (this.buffer.length > 16 * 1024 * 1024) {
      this.lost(new Error("Codex sent an oversized protocol frame."));
      return;
    }
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      let frame: JsonObject;
      try {
        frame = object(JSON.parse(line));
      } catch {
        continue;
      }
      const id = frame["id"];
      if (typeof frame["method"] === "string") {
        const params = object(frame["params"]);
        if (typeof id === "number" || typeof id === "string") {
          this.emit("request", { id, method: frame["method"], params });
        } else {
          this.emit("notification", frame["method"], params);
        }
      } else if (typeof id === "number" || typeof id === "string") {
        const pending = this.pending.get(id);
        if (!pending) continue;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        if (frame["error"]) {
          const error = object(frame["error"]);
          pending.reject(
            new Error(
              typeof error["message"] === "string" ? error["message"] : "Codex request failed.",
            ),
          );
        } else pending.resolve(frame["result"]);
      }
    }
  }

  private lost(error: Error): void {
    if (!this.child) return;
    const child = this.child;
    this.child = null;
    child.kill("SIGTERM");
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    if (!this.closing) this.emit("closed", error);
  }
}
