import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { dirname, join } from "node:path";
import type { HostedSession } from "../acp/hosted_session.ts";
import type { SessionHub } from "../acp/hub.ts";
import { BAYA_HOME } from "../config.ts";
import { removePeers } from "../pairing/storage.ts";
import { issuePendingPairToken } from "../pairing/token_store.ts";
import { packageVersion } from "../runtime/version.ts";
import { resolveDirectory } from "../workspace/directories.ts";
import type {
  ControlInfo,
  ControlRequest,
  ControlResponse,
  HostStatus,
  SessionStatus,
} from "./protocol.ts";

export function sessionStatus(session: HostedSession): SessionStatus {
  const info = session.info()["_meta"] as { baya: { error?: string } };
  return {
    id: session.id,
    title: session.title,
    cwd: session.record.cwd,
    agent: session.record.agent,
    running: session.running,
    working: session.working,
    error: info.baya.error ?? null,
  };
}

export function controlInfoPath(): string {
  return join(BAYA_HOME, "runtime", "control.json");
}

export class ControlServer {
  private server: Server | null = null;
  private readonly token = randomBytes(32).toString("base64url");
  private readonly startedAt = Date.now();
  /** Short tailnet name phones can type to pair, when Tailscale is on. */
  tailnetName: string | null = null;
  /** Where phones connect, when `tailscale serve` routes to this host. */
  direct: string | null = null;

  private readonly hub: SessionHub;
  private readonly stopProcess: () => void;

  constructor(hub: SessionHub, stopProcess: () => void) {
    this.hub = hub;
    this.stopProcess = stopProcess;
  }

  async start(): Promise<ControlInfo> {
    const server = createServer((socket) => this.accept(socket));
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", reject);
        resolve();
      });
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("Could not allocate the Baya control socket.");
    }
    const info: ControlInfo = {
      port: address.port,
      token: this.token,
      pid: process.pid,
      started_at: Date.now(),
    };
    mkdirSync(dirname(controlInfoPath()), { recursive: true, mode: 0o700 });
    writeFileSync(controlInfoPath(), `${JSON.stringify(info, null, 2)}\n`, { mode: 0o600 });
    return info;
  }

  async close(): Promise<void> {
    const server = this.server;
    this.server = null;
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    if (existsSync(controlInfoPath())) {
      try {
        unlinkSync(controlInfoPath());
      } catch {
        // Another process may already have replaced/removed it.
      }
    }
  }

  private accept(socket: Socket): void {
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > 1024 * 1024) {
        socket.destroy();
        return;
      }
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const line = buffer.slice(0, newline);
      buffer = "";
      void this.handleLine(socket, line);
    });
  }

  private async handleLine(socket: Socket, line: string): Promise<void> {
    let request: ControlRequest;
    try {
      request = JSON.parse(line) as ControlRequest;
    } catch {
      socket.end(`${JSON.stringify({ id: "", ok: false, error: "Invalid JSON." })}\n`);
      return;
    }
    if (request.token !== this.token) {
      socket.end(`${JSON.stringify({ id: request.id, ok: false, error: "Unauthorized." })}\n`);
      return;
    }

    let response: ControlResponse;
    try {
      response = { id: request.id, ok: true, data: await this.dispatch(request) };
    } catch (error) {
      response = {
        id: request.id,
        ok: false,
        error: error instanceof Error ? error.message : "Control request failed.",
      };
    }
    socket.end(`${JSON.stringify(response)}\n`);
    if (request.command === "stop" && response.ok) {
      setTimeout(this.stopProcess, 20);
    }
  }

  private async dispatch(request: ControlRequest): Promise<unknown> {
    const params = request.params ?? {};
    switch (request.command) {
      case "status":
        return {
          pid: process.pid,
          version: packageVersion(),
          started_at: this.startedAt,
          tailnet: this.tailnetName,
          direct: this.direct,
          phones_connected: this.hub.connectedPhones,
          sessions: this.hub.list().map(sessionStatus),
        } satisfies HostStatus;
      case "open": {
        if (typeof params["cwd"] !== "string") throw new Error("cwd is required.");
        const agent = typeof params["agent"] === "string" ? params["agent"] : undefined;
        return sessionStatus(this.hub.create(await resolveDirectory(params["cwd"]), agent));
      }
      case "remove": {
        if (typeof params["id"] !== "string") throw new Error("id is required.");
        return { removed: this.hub.delete(params["id"]) };
      }
      case "pair": {
        const ttlMs =
          typeof params["ttl_ms"] === "number" && Number.isFinite(params["ttl_ms"])
            ? params["ttl_ms"]
            : undefined;
        return issuePendingPairToken(ttlMs);
      }
      case "unpair": {
        if (typeof params["query"] !== "string") throw new Error("query is required.");
        const removed = await removePeers(params["query"]);
        await this.hub.refreshPeers();
        return { removed };
      }
      case "stop":
        return { stopping: true };
    }
  }
}
