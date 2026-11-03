import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import type { AgentDefinition } from "../config.ts";
import { spawnPlan, terminateChild } from "../process/spawn.ts";
import { packageVersion } from "../runtime/version.ts";
import { type Json, JsonRpcPeer, NdjsonDecoder, type RequestHandler } from "./jsonrpc.ts";
import { type InitializeResponse, PROTOCOL_VERSION } from "./schema.ts";

interface AgentProcessHandlers {
  onRequest: RequestHandler;
  onNotification: (method: string, params: Json) => void;
  onExit: (error: Error) => void;
}

const STDERR_TAIL = 2_000;

/**
 * One ACP agent child process. Baya is its client: it advertises no file
 * system or terminal capability, so agents use their own tools on the
 * computer, which is where the files are anyway.
 */
export class AgentProcess {
  readonly definition: AgentDefinition;
  private child: ChildProcessWithoutNullStreams | null = null;
  private peer: JsonRpcPeer | null = null;
  private stderrTail = "";
  info: InitializeResponse | null = null;

  constructor(definition: AgentDefinition) {
    this.definition = definition;
  }

  async start(cwd: string, handlers: AgentProcessHandlers): Promise<InitializeResponse> {
    const [executable, ...args] = this.definition.command;
    const plan = spawnPlan(executable!, args);
    const child = spawn(plan.command, plan.prefixArgs, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
      env: { ...process.env },
    });
    this.child = child;
    const peer = new JsonRpcPeer({
      write: (message) => {
        if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
      },
      onRequest: handlers.onRequest,
      onNotification: handlers.onNotification,
    });
    this.peer = peer;
    const decoder = new NdjsonDecoder();
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) =>
      decoder.push(chunk, (message) => peer.receive(message)),
    );
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      this.stderrTail = (this.stderrTail + chunk).slice(-STDERR_TAIL);
      process.stderr.write(`[${this.definition.id}] ${chunk}`);
    });
    child.stdin.on("error", () => {});
    let exited = false;
    const exit = (error: Error): void => {
      if (exited) return;
      exited = true;
      peer.close(error);
      this.child = null;
      handlers.onExit(error);
    };
    child.on("error", (error) =>
      exit(new Error(`${this.definition.name} could not start: ${error.message}`)),
    );
    child.on("exit", (code, signal) => {
      const tail = this.stderrTail.trim().split(/\r?\n/u).at(-1);
      exit(
        new Error(
          `${this.definition.name} stopped (${code ?? signal ?? "unknown"})${tail ? `: ${tail}` : ""}`,
        ),
      );
    });

    this.info = await peer.request<InitializeResponse>("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "baya", title: "Baya", version: packageVersion() },
    });
    if (this.info.protocolVersion !== PROTOCOL_VERSION) {
      this.stop();
      throw new Error(
        `${this.definition.name} speaks ACP ${this.info.protocolVersion}; Baya needs ${PROTOCOL_VERSION}.`,
      );
    }
    return this.info;
  }

  request<T = Json>(method: string, params: Json): Promise<T> {
    if (!this.peer) return Promise.reject(new Error(`${this.definition.name} is not running.`));
    return this.peer.request<T>(method, params);
  }

  notify(method: string, params: Json): void {
    this.peer?.notify(method, params);
  }

  get running(): boolean {
    return this.child !== null;
  }

  stop(): void {
    this.peer?.close(new Error(`${this.definition.name} stopped.`));
    terminateChild(this.child);
    this.child = null;
  }
}
