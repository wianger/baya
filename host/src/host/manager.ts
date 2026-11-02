import { PiAdapter } from "../adapters/pi.ts";
import type { AdapterOptions, AgentAdapter } from "../adapters/types.ts";
import { CodexSession } from "../codex/session.ts";
import { loadConfig } from "../config.ts";
import { DeepSeekSession } from "../deepseek/session.ts";
import { issuePendingPairToken, type PendingPairToken } from "../pairing/token_store.ts";
import { sessionStatePath } from "../session/identity.ts";
import {
  addSession,
  type BayaSessionRecord,
  defaultSessionName,
  findSession,
  listSessions,
  removeSession,
  updateSession,
} from "../session/registry.ts";
import { workspaceAgentDefinition } from "../workspace/agents.ts";
import { availableAgents } from "../workspace/directories.ts";
import type { OpenedWorkspace, WorkspaceAgent } from "../workspace/types.ts";
import { ManagedSessionHost, roomIdForBayaSession } from "./session_host.ts";

/** Restart delays after an agent process exits unexpectedly. */
const RESTART_DELAYS_MS = [1_000, 5_000, 15_000, 60_000];
/** A run this long resets the crash counter. */
const HEALTHY_RUN_MS = 5 * 60_000;

export interface SessionStatus extends BayaSessionRecord {
  online: boolean;
  busy: boolean;
  room_id: string;
}

export class BayaManager {
  private readonly hosts = new Map<string, ManagedSessionHost>();
  private readonly restarts = new Map<string, { attempt: number; timer: NodeJS.Timeout | null }>();
  private stopped = false;

  async start(initial?: { cwd?: string; agent?: WorkspaceAgent; name?: string }): Promise<void> {
    let sessions = listSessions();
    if (sessions.length === 0) {
      sessions = [
        addSession({
          cwd: initial?.cwd || process.cwd(),
          agent: initial?.agent || (await this.defaultAgent()),
          ...(initial?.name ? { name: initial.name } : {}),
        }),
      ];
    }
    // Agents start in the background: a slow or broken agent must not keep
    // the host (CLI, pairing, phone connections) from coming up. Failures retry with
    // the same backoff as a crash.
    for (const session of sessions) {
      this.startSession(session).catch((error: unknown) => {
        process.stderr.write(`[baya] ${errorMessage(error)}\n`);
        this.scheduleRestart(session.id, 0);
      });
    }
  }

  list(): SessionStatus[] {
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
      name: defaultSessionName(path),
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

  deleteById(id: string): boolean {
    const record = findSession(id);
    if (!record) return false;
    this.stopSession(record.id);
    return removeSession(record.id);
  }

  pair(
    id?: string,
    ttlMs?: number,
  ): PendingPairToken & { session_id: string; session_name: string } {
    // Prefer a live session, but one that is still starting is fine: the
    // token only names its room, which answers once the agent is up.
    const sessions = this.list();
    const record = id ? findSession(id) : (sessions.find((s) => s.online) ?? sessions[0]);
    if (!record) {
      throw new Error(id ? `No session matches "${id}".` : "No Baya session is registered.");
    }
    return {
      ...issuePendingPairToken(roomIdForBayaSession(record), ttlMs),
      session_id: record.id,
      session_name: record.name,
    };
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const id of [...this.hosts.keys(), ...this.restarts.keys()]) this.stopSession(id);
  }

  private stopSession(id: string): void {
    const restart = this.restarts.get(id);
    if (restart?.timer) clearTimeout(restart.timer);
    this.restarts.delete(id);
    this.hosts.get(id)?.stop();
    this.hosts.delete(id);
  }

  private async startSession(record: BayaSessionRecord): Promise<void> {
    if (this.hosts.has(record.id)) return;
    const host = new ManagedSessionHost(record, this.adapterFor(record), (path, agent) =>
      this.openWorkspace(path, agent),
    );
    this.hosts.set(record.id, host);
    try {
      await host.start();
    } catch (error) {
      this.hosts.delete(record.id);
      host.stop();
      throw new Error(`Could not start ${record.name}: ${errorMessage(error)}`);
    }
  }

  /** The agent process died. Keep the session registered and bring it back. */
  private onAgentExit(record: BayaSessionRecord, error: Error): void {
    const host = this.hosts.get(record.id);
    if (!host || this.stopped) return;
    process.stderr.write(`[baya] ${record.name}: ${error.message}\n`);
    this.hosts.delete(record.id);
    host.stop();
    this.scheduleRestart(record.id, Date.now() - host.startedAt);
  }

  private scheduleRestart(id: string, ranForMs: number): void {
    const state = this.restarts.get(id) ?? { attempt: 0, timer: null };
    if (ranForMs > HEALTHY_RUN_MS) state.attempt = 0;
    const delay = RESTART_DELAYS_MS[Math.min(state.attempt, RESTART_DELAYS_MS.length - 1)]!;
    state.attempt++;
    state.timer = setTimeout(() => {
      state.timer = null;
      const record = findSession(id);
      if (this.stopped || !record) return;
      this.startSession(record).catch((error: unknown) => {
        process.stderr.write(`[baya] ${errorMessage(error)}\n`);
        this.scheduleRestart(id, 0);
      });
    }, delay);
    state.timer.unref();
    this.restarts.set(id, state);
  }

  private adapterFor(record: BayaSessionRecord): AgentAdapter {
    const host = () => this.hosts.get(record.id);
    const shared = {
      cwd: record.cwd,
      broadcast: (message: Parameters<AdapterOptions["broadcast"]>[0]) =>
        host()?.broadcast(message),
      onBusy: (busy: boolean) => host()?.setBusy(busy),
      onModel: (model: string) => host()?.setModel(model),
      onClosed: (error: Error) => this.onAgentExit(record, error),
    };
    switch (record.agent) {
      case "pi":
        return new PiAdapter({
          ...shared,
          name: record.name,
          sessionId: record.id,
          ...(record.pi_session_id ? { nativeSessionId: record.pi_session_id } : {}),
          onNativeSessionId: (nativeSessionId) =>
            updateSession(record.id, { pi_session_id: nativeSessionId }),
        });
      case "codex":
        return new CodexSession({
          ...shared,
          statePath: sessionStatePath(record.cwd, record.agent, record.id),
        });
      case "deepseek":
        return new DeepSeekSession({
          ...shared,
          statePath: sessionStatePath(record.cwd, record.agent, record.id),
        });
      default:
        throw new Error(`No Baya adapter is installed for ${String(record.agent)}.`);
    }
  }

  private async defaultAgent(): Promise<WorkspaceAgent> {
    const configured = loadConfig().defaultAgent;
    if (configured) return configured;
    const available = await availableAgents();
    return (
      available.find((entry) => entry.id === "pi" && entry.available)?.id ??
      available.find((entry) => entry.available)?.id ??
      "pi"
    );
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
