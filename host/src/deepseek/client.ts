import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { resolveSpawnTarget, spawnPlan } from "../process/spawn.js";
import { packageVersion } from "../runtime/version.js";
import { resolveDeepSeekExecutable } from "../workspace/dsh_executable.js";

export type JsonObject = Record<string, unknown>;
export type RpcId = number | string;

export interface DeepSeekSpawnPlan {
  command: string;
  args: string[];
  /** Node must not re-quote: the command line is already cmd.exe-shaped. */
  windowsVerbatimArguments: boolean;
}

/**
 * Turn the resolved executable into something `spawn` accepts.
 *
 * `resolvePiSpawn` unwraps npm shims and Pi's managed launcher, but the
 * DeepSeek Harness desktop bundle ships its own `dsh.cmd` that sets
 * `ELECTRON_RUN_AS_NODE=1` and boots the app's `DeepSeek Harness.exe`. Modern
 * Node refuses to `spawn` a `.cmd` directly (EINVAL, post CVE-2024-27980), so
 * that shim has to run through `cmd.exe`.
 */
export function deepSeekSpawnPlan(
  target: { command: string; prefixArgs: string[] },
  args: string[],
  plat: NodeJS.Platform = process.platform,
  comSpec: string = process.env["ComSpec"]?.trim() || "cmd.exe",
): DeepSeekSpawnPlan {
  const all = [...target.prefixArgs, ...args];
  if (plat === "win32" && /\.(cmd|bat)$/i.test(target.command)) {
    const line = [
      `"${target.command}"`,
      ...all.map((arg) => /[\s"]/.test(arg) ? `"${arg.replace(/"/g, '""')}"` : arg),
    ].join(" ");
    // `/s` strips the outer pair of quotes, leaving the quoted shim path plus
    // its arguments for cmd to run verbatim.
    return {
      command: comSpec,
      args: ["/d", "/s", "/c", `"${line}"`],
      windowsVerbatimArguments: true,
    };
  }
  return { command: target.command, args: all, windowsVerbatimArguments: false };
}

export interface DeepSeekServerRequest {
  id: RpcId;
  method: string;
  params: JsonObject;
}

export interface DeepSeekClientEvents {
  notification: [method: string, params: JsonObject];
  request: [request: DeepSeekServerRequest];
  closed: [error: Error];
}

export interface DeepSeekStartResult {
  supportsImages: boolean;
}

export function object(value: unknown): JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

/** Official DeepSeek Harness ACP v1 over a private JSON-RPC stdio pipe. */
export class DeepSeekClient extends EventEmitter<DeepSeekClientEvents> {
  private child: ChildProcessWithoutNullStreams | null = null;
  private sequence = 0;
  private buffer = "";
  private closing = false;
  private started: DeepSeekStartResult | null = null;
  private readonly pending = new Map<RpcId, {
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout> | null;
  }>();

  constructor(
    private readonly cwd: string,
    private executable =
      process.env["BAYA_DSH_BIN"]?.trim() || "dsh",
  ) {
    super();
  }

  async start(): Promise<DeepSeekStartResult> {
    if (this.child && this.started) return this.started;
    // `dsh` may live inside the DeepSeek Harness desktop bundle rather than on
    // PATH; resolve once so the spawned ACP host is the real executable.
    if (
      !process.env["BAYA_DSH_BIN"]?.trim() &&
      this.executable === "dsh"
    ) {
      this.executable = await resolveDeepSeekExecutable();
    }
    const target = resolveSpawnTarget(this.executable);
    const plan = deepSeekSpawnPlan(target, ["--profile", "acp"]);
    this.closing = false;
    const child = spawn(plan.command, plan.args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
      env: { ...process.env },
    });
    this.child = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.receive(chunk));
    // Harness logs and credentials stay on the computer. Stdout is protocol-only.
    child.stderr.on("data", (chunk: Buffer) => process.stderr.write(chunk));
    child.on("error", (error) => this.lost(error));
    child.on("exit", (code) => this.lost(
      new Error(`DeepSeek Harness stopped (${code ?? "signal"}).`),
    ));
    const initialized = object(await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: {
        name: "baya",
        title: "Baya",
        version: packageVersion(),
      },
    }, 120_000));
    if (initialized.protocolVersion !== 1) {
      this.close();
      throw new Error(
        `DeepSeek Harness uses unsupported ACP version ${String(initialized.protocolVersion)}.`,
      );
    }
    const capabilities = object(initialized.agentCapabilities);
    const promptCapabilities = object(capabilities.promptCapabilities);
    this.started = { supportsImages: promptCapabilities.image === true };
    return this.started;
  }

  request(
    method: string,
    params: JsonObject = {},
    timeoutMs = 120_000,
  ): Promise<unknown> {
    if (!this.child) return Promise.reject(new Error("DeepSeek Harness is not connected."));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(new Error(`DeepSeek Harness did not answer ${method} in time.`));
          }, timeoutMs)
        : null;
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        if (timer) clearTimeout(timer);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("Could not send to DeepSeek Harness."));
      }
    });
  }

  notify(method: string, params: JsonObject = {}): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  respond(id: RpcId, result: unknown): void {
    this.write({ jsonrpc: "2.0", id, result });
  }

  rejectRequest(id: RpcId, message: string): void {
    this.write({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message },
    });
  }

  close(): void {
    this.closing = true;
    this.started = null;
    const child = this.child;
    this.child = null;
    this.started = null;
    for (const pending of this.pending.values()) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.reject(new Error("DeepSeek Harness connection closed."));
    }
    this.pending.clear();
    if (child) {
      child.stdin.end();
      child.kill("SIGTERM");
    }
  }

  private write(message: JsonObject): void {
    if (!this.child || !this.child.stdin.writable) {
      throw new Error("DeepSeek Harness is not connected.");
    }
    this.child.stdin.write(JSON.stringify(message) + "\n");
  }

  private receive(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > 16 * 1024 * 1024) {
      this.lost(new Error("DeepSeek Harness sent an oversized protocol frame."));
      return;
    }
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let frame: JsonObject;
      try {
        frame = object(JSON.parse(line));
      } catch {
        this.lost(new Error("DeepSeek Harness sent invalid JSON on its protocol stream."));
        return;
      }
      const id = frame.id;
      if (typeof frame.method === "string") {
        const params = object(frame.params);
        if (typeof id === "number" || typeof id === "string") {
          this.emit("request", { id, method: frame.method, params });
        } else {
          this.emit("notification", frame.method, params);
        }
      } else if (typeof id === "number" || typeof id === "string") {
        const pending = this.pending.get(id);
        if (!pending) continue;
        this.pending.delete(id);
        if (pending.timer) clearTimeout(pending.timer);
        if (frame.error) {
          const error = object(frame.error);
          pending.reject(new Error(
            typeof error.message === "string"
              ? error.message
              : "DeepSeek Harness request failed.",
          ));
        } else {
          pending.resolve(frame.result);
        }
      }
    }
  }

  private lost(error: Error): void {
    if (!this.child) return;
    const child = this.child;
    this.child = null;
    child.kill("SIGTERM");
    for (const pending of this.pending.values()) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    if (!this.closing) this.emit("closed", error);
  }
}
