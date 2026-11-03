import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";
import { terminateChild } from "../process/spawn.ts";
import { type Json, RpcError } from "./jsonrpc.ts";

/** What phones see of a terminal: its output so far and how it ended. */
export interface TerminalSnapshot {
  terminalId: string;
  output: string;
  truncated: boolean;
  exitStatus: { exitCode: number | null; signal: string | null } | null;
}

const DEFAULT_OUTPUT_LIMIT = 256 * 1024;

class Terminal {
  readonly id = `term-${randomUUID()}`;
  private chunks = "";
  private truncated = false;
  exitStatus: TerminalSnapshot["exitStatus"] = null;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly limit: number;
  readonly exited: Promise<TerminalSnapshot["exitStatus"]>;

  constructor(
    command: string,
    args: string[],
    options: { cwd: string; env: Record<string, string>; limit: number },
    onChange: () => void,
  ) {
    this.limit = options.limit;
    this.child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.child.stdin.end();
    const append = (chunk: Buffer) => {
      this.chunks += chunk.toString("utf8");
      // Keep the tail within the byte limit, cutting on a character boundary.
      while (Buffer.byteLength(this.chunks) > this.limit) {
        this.chunks = this.chunks.slice(Math.max(1, this.chunks.length - this.limit));
        this.truncated = true;
      }
      onChange();
    };
    this.child.stdout.on("data", append);
    this.child.stderr.on("data", append);
    this.exited = new Promise((resolve) => {
      const finish = (status: TerminalSnapshot["exitStatus"]) => {
        if (this.exitStatus) return;
        this.exitStatus = status;
        onChange();
        resolve(status);
      };
      this.child.on("exit", (code, signal) => finish({ exitCode: code, signal: signal ?? null }));
      this.child.on("error", (error) => {
        append(Buffer.from(`${error.message}\n`));
        finish({ exitCode: null, signal: null });
      });
    });
  }

  snapshot(): TerminalSnapshot {
    return {
      terminalId: this.id,
      output: this.chunks,
      truncated: this.truncated,
      exitStatus: this.exitStatus,
    };
  }

  kill(): void {
    if (!this.exitStatus) terminateChild(this.child);
  }
}

/**
 * The client half of ACP that Baya provides to agents on the phone's
 * behalf: files and terminals live on this computer, so the host answers
 * `fs/*` and `terminal/*` itself and shows terminals to phones as they run.
 */
export class ClientServices {
  private readonly terminals = new Map<string, Terminal>();
  private readonly cwd: () => string;
  private readonly onTerminal: (snapshot: TerminalSnapshot) => void;

  constructor(options: { cwd: () => string; onTerminal: (snapshot: TerminalSnapshot) => void }) {
    this.cwd = options.cwd;
    this.onTerminal = options.onTerminal;
  }

  static handles(method: string): boolean {
    return method.startsWith("fs/") || method.startsWith("terminal/");
  }

  async handle(method: string, params: Json): Promise<unknown> {
    switch (method) {
      case "fs/read_text_file": {
        const text = await readFile(absolute(params["path"]), "utf8");
        const line = typeof params["line"] === "number" ? Math.max(1, params["line"]) : 1;
        const limit = typeof params["limit"] === "number" ? params["limit"] : undefined;
        if (line === 1 && limit === undefined) return { content: text };
        const lines = text.split("\n");
        return {
          content: lines
            .slice(line - 1, limit === undefined ? undefined : line - 1 + limit)
            .join("\n"),
        };
      }
      case "fs/write_text_file": {
        const path = absolute(params["path"]);
        if (typeof params["content"] !== "string")
          throw RpcError.invalidParams("content is required.");
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path, params["content"], "utf8");
        return {};
      }
      case "terminal/create": {
        if (typeof params["command"] !== "string")
          throw RpcError.invalidParams("command is required.");
        const env = Object.fromEntries(
          (Array.isArray(params["env"]) ? params["env"] : []).flatMap((entry: unknown) => {
            const { name, value } = (entry ?? {}) as { name?: unknown; value?: unknown };
            return typeof name === "string" && typeof value === "string" ? [[name, value]] : [];
          }),
        );
        const limit =
          typeof params["outputByteLimit"] === "number"
            ? Math.min(params["outputByteLimit"], DEFAULT_OUTPUT_LIMIT)
            : DEFAULT_OUTPUT_LIMIT;
        let terminal: Terminal | undefined;
        let pending: NodeJS.Timeout | null = null;
        // Phones get at most a few updates a second.
        const changed = () => {
          if (pending || !terminal) return;
          pending = setTimeout(() => {
            pending = null;
            if (terminal) this.onTerminal(terminal.snapshot());
          }, 150);
        };
        terminal = new Terminal(
          params["command"],
          (Array.isArray(params["args"]) ? params["args"] : []).map(String),
          {
            cwd: typeof params["cwd"] === "string" ? params["cwd"] : this.cwd(),
            env,
            limit,
          },
          changed,
        );
        this.terminals.set(terminal.id, terminal);
        this.onTerminal(terminal.snapshot());
        return { terminalId: terminal.id };
      }
      case "terminal/output": {
        const { output, truncated, exitStatus } = this.terminal(params).snapshot();
        return { output, truncated, ...(exitStatus ? { exitStatus } : {}) };
      }
      case "terminal/wait_for_exit":
        return (await this.terminal(params).exited) ?? { exitCode: null, signal: null };
      case "terminal/kill":
        this.terminal(params).kill();
        return {};
      case "terminal/release": {
        const terminal = this.terminal(params);
        terminal.kill();
        this.onTerminal(terminal.snapshot());
        this.terminals.delete(terminal.id);
        return {};
      }
      default:
        throw RpcError.methodNotFound(method);
    }
  }

  private terminal(params: Json): Terminal {
    const terminal = this.terminals.get(String(params["terminalId"]));
    if (!terminal) throw RpcError.notFound("No such terminal.");
    return terminal;
  }

  /** Stops every terminal (the agent went away). */
  dispose(): void {
    for (const terminal of this.terminals.values()) terminal.kill();
    this.terminals.clear();
  }
}

function absolute(path: unknown): string {
  if (typeof path !== "string" || !isAbsolute(path)) {
    throw RpcError.invalidParams("ACP file paths must be absolute.");
  }
  return path;
}
