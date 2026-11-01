import type {
  AgentAdapter,
  AdapterOptions,
} from "../adapters/types.js";
import { PiAdapter } from "../adapters/pi.js";
import { CodexSession } from "../codex/session.js";
import { DeepSeekSession } from "../deepseek/session.js";
import type {
  OpenedWorkspace,
  WorkspaceAgent,
} from "../workspace/types.js";
import {
  addSession,
  defaultSessionName,
  listSessions,
  removeSession,
  updateSession,
  type BayaSessionRecord,
} from "../session/registry.js";
import { sessionStatePath } from "../session/identity.js";
import { availableAgents } from "../workspace/directories.js";
import { workspaceAgentDefinition } from "../workspace/agents.js";
import { ManagedSessionHost, roomIdForBayaSession } from "./session_host.js";
import {
  issuePendingPairToken,
  type PendingPairToken,
} from "../pairing/token_store.js";

class WrappedAgentAdapter implements AgentAdapter {
  constructor(
    readonly agent: WorkspaceAgent,
    private readonly session: CodexSession | DeepSeekSession,
  ) {}

  get isBusy(): boolean {
    return this.session.isBusy;
  }

  start(): Promise<void> {
    return this.session.start();
  }

  handle(sender: Parameters<CodexSession["handle"]>[0], message: Parameters<CodexSession["handle"]>[1]) {
    return this.session.handle(sender, message);
  }

  close(): void {
    this.session.close();
  }
}

export class BayaManager {
  private readonly hosts = new Map<string, ManagedSessionHost>();

  async start(initial?: { cwd?: string; agent?: WorkspaceAgent; name?: string }): Promise<void> {
    let sessions = listSessions();
    if (sessions.length === 0) {
      const cwd = initial?.cwd || process.cwd();
      const agent = initial?.agent || await this.defaultAgent();
      sessions = [addSession({
        cwd,
        agent,
        ...(initial?.name ? { name: initial.name } : {}),
      })];
    }
    const failures: Error[] = [];
    for (const session of sessions) {
      try {
        await this.startSession(session);
      } catch (error) {
        const failure = error instanceof Error ? error : new Error(String(error));
        failures.push(failure);
        process.stderr.write(`[baya] ${failure.message}\n`);
      }
    }
    if (sessions.length > 0 && failures.length === sessions.length) {
      throw new Error("No Baya session could be started. Run `baya doctor` for diagnostics.");
    }
  }

  list(): Array<BayaSessionRecord & { online: boolean; room_id: string; busy: boolean }> {
    return listSessions().map((record) => ({
      ...record,
      online: this.hosts.has(record.id),
      room_id: roomIdForBayaSession(record),
      busy: this.hosts.get(record.id)?.isBusy ?? false,
    }));
  }

  async openWorkspace(path: string, agentId: unknown): Promise<OpenedWorkspace> {
    const definition = workspaceAgentDefinition(agentId);
    if (!definition) throw new Error("Choose an agent supported by this computer.");
    const available = await availableAgents();
    if (!available.find((entry) => entry.id === definition.id)?.available) {
      throw new Error(`${definition.name} is not installed on this computer.`);
    }
    const record = addSession({
      cwd: path,
      agent: definition.id,
      name: defaultSessionName(path, definition.id),
    });
    await this.startSession(record);
    return {
      id: record.id,
      cwd: record.cwd,
      name: record.name,
      agent: record.agent,
      room_id: roomIdForBayaSession(record),
      existing: false,
    };
  }

  create(input: { cwd: string; agent?: WorkspaceAgent; name?: string }): BayaSessionRecord {
    return addSession({
      cwd: input.cwd,
      agent: input.agent || "pi",
      ...(input.name ? { name: input.name } : {}),
    });
  }

  async startById(id: string): Promise<BayaSessionRecord | null> {
    const record = listSessions().find((entry) => entry.id === id) || null;
    if (!record) return null;
    await this.startSession(record);
    return record;
  }

  stopById(id: string): boolean {
    const host = this.hosts.get(id);
    if (!host) return false;
    host.stop();
    this.hosts.delete(id);
    return true;
  }

  deleteById(id: string): boolean {
    this.stopById(id);
    return removeSession(id);
  }

  pair(id?: string, ttlMs?: number): PendingPairToken {
    const sessions = listSessions();
    const record = id ? sessions.find((entry) => entry.id === id || entry.id.startsWith(id)) : sessions[0];
    if (!record) throw new Error("No Baya session is registered. Run `baya new` first.");
    if (!this.hosts.has(record.id)) {
      throw new Error("The selected session is not online. Run `baya start` first.");
    }
    return issuePendingPairToken(roomIdForBayaSession(record), ttlMs);
  }

  async stop(): Promise<void> {
    for (const host of this.hosts.values()) host.stop();
    this.hosts.clear();
  }

  private async startSession(record: BayaSessionRecord): Promise<void> {
    if (this.hosts.has(record.id)) return;
    const adapter = this.adapterFor(record);
    const host = new ManagedSessionHost(
      record,
      adapter,
      (path, agent) => this.openWorkspace(path, agent),
    );
    this.hosts.set(record.id, host);
    try {
      await host.start();
    } catch (error) {
      this.hosts.delete(record.id);
      host.stop();
      throw new Error(
        `Could not start ${record.name}: ${
          error instanceof Error ? error.message : "unknown error"
        }`,
      );
    }
  }

  private adapterFor(record: BayaSessionRecord): AgentAdapter {
    const options: AdapterOptions = {
      cwd: record.cwd,
      name: record.name,
      sessionId: record.id,
      ...(record.pi_session_id ? { nativeSessionId: record.pi_session_id } : {}),
      broadcast: (message) => {
        const host = this.hosts.get(record.id);
        host?.broadcast(message);
      },
      onBusy: (busy) => {
        const host = this.hosts.get(record.id);
        host?.setBusy(busy);
      },
      onModel: (model) => {
        const host = this.hosts.get(record.id);
        host?.setModel(model);
      },
      onClosed: (error) => {
        process.stderr.write(`[baya] ${record.name}: ${error.message}\n`);
        const current = this.hosts.get(record.id);
        this.hosts.delete(record.id);
        current?.stop();
      },
      onNativeSessionId: (nativeSessionId) => {
        updateSession(record.id, { pi_session_id: nativeSessionId });
      },
    };

    if (record.agent === "pi") {
      // The callback is rebound by ManagedSessionHost before start.
      return new PiAdapter(options);
    }
    if (record.agent === "codex") {
      const session = new CodexSession({
        cwd: record.cwd,
        broadcast: options.broadcast,
        ...(options.onBusy ? { onBusy: options.onBusy } : {}),
        ...(options.onModel ? { onModel: options.onModel } : {}),
        ...(options.onClosed ? { onClosed: options.onClosed } : {}),
        statePath: sessionStatePath(record.cwd, record.agent, record.id),
      });
      return new WrappedAgentAdapter(record.agent, session);
    }
    if (record.agent === "deepseek") {
      const session = new DeepSeekSession({
        cwd: record.cwd,
        broadcast: options.broadcast,
        ...(options.onBusy ? { onBusy: options.onBusy } : {}),
        ...(options.onModel ? { onModel: options.onModel } : {}),
        ...(options.onClosed ? { onClosed: options.onClosed } : {}),
        statePath: sessionStatePath(record.cwd, record.agent, record.id),
      });
      return new WrappedAgentAdapter(record.agent, session);
    }
    throw new Error(`No Baya adapter is installed for ${record.agent}.`);
  }

  private async defaultAgent(): Promise<WorkspaceAgent> {
    const configured = (await import("../config.js")).loadConfig().defaultAgent;
    if (configured) return configured;
    const available = await availableAgents();
    return available.find((entry) => entry.id === "pi" && entry.available)?.id
      ?? available.find((entry) => entry.available)?.id
      ?? "pi";
  }
}
