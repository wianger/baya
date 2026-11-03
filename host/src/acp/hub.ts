import { type AgentDefinition, defaultAgentId, loadConfig } from "../config.ts";
import { isPairedKey, listPeers, type PeerRecord } from "../pairing/storage.ts";
import {
  addSession,
  listSessions,
  removeSession,
  type SessionRecord,
} from "../session/registry.ts";
import { findExecutable } from "../workspace/directories.ts";
import { HostedSession, type PhoneLink } from "./hosted_session.ts";

export interface AgentInfo {
  id: string;
  name: string;
  command: string[];
  available: boolean;
}

/** A phone connection as the hub sees it. */
export interface HubPhone extends PhoneLink {
  /** True once the phone sent `initialize`; only then does it get pushes. */
  readonly ready: boolean;
  close(code: number, reason: string): void;
}

export const CLOSE_UNPAIRED = 4003;

/**
 * Every session on this computer and every connected phone. Sessions load
 * from the registry at start; their agents start only when used.
 */
export class SessionHub {
  private readonly sessions = new Map<string, HostedSession>();
  private readonly phones = new Set<HubPhone>();
  private peers: PeerRecord[] = [];
  private readonly persist: boolean;

  constructor(options: { persist?: boolean } = {}) {
    this.persist = options.persist ?? true;
  }

  async start(): Promise<void> {
    this.peers = await listPeers();
    for (const record of listSessions()) this.adopt(record);
  }

  // ── agents ──────────────────────────────────────────────────────────────

  definition(id: string): AgentDefinition | null {
    return loadConfig().agents.find((agent) => agent.id === id) ?? null;
  }

  async agents(): Promise<AgentInfo[]> {
    return Promise.all(
      loadConfig().agents.map(async (agent) => ({
        ...agent,
        available: (await findExecutable(agent.command[0]!)) !== null,
      })),
    );
  }

  // ── sessions ────────────────────────────────────────────────────────────

  list(cwd?: string): HostedSession[] {
    return [...this.sessions.values()]
      .filter((session) => !cwd || session.record.cwd === cwd)
      .toSorted((a, b) => b.record.updatedAt - a.record.updatedAt);
  }

  get(id: string): HostedSession | undefined {
    return this.sessions.get(id);
  }

  create(cwd: string, agent?: string, title?: string): HostedSession {
    const id = agent ?? defaultAgentId();
    if (!id) throw new Error("No agent is set up on this computer. Add one: baya agents add");
    if (!this.definition(id)) throw new Error(`No agent named "${id}" is set up on this computer.`);
    const session = this.adopt(addSession({ cwd, agent: id, ...(title ? { title } : {}) }));
    this.changed(session);
    return session;
  }

  delete(id: string): boolean {
    const session = this.sessions.get(id);
    if (!session) return false;
    this.sessions.delete(id);
    session.destroy();
    removeSession(id);
    this.push("_baya/session_removed", { sessionId: id });
    return true;
  }

  stop(): void {
    for (const session of this.sessions.values()) session.stop();
  }

  private adopt(record: SessionRecord): HostedSession {
    const session = new HostedSession(
      record,
      () => this.definition(record.agent),
      { changed: (changed) => this.changed(changed) },
      this.persist,
    );
    this.sessions.set(record.id, session);
    return session;
  }

  private changed(session: HostedSession): void {
    if (this.sessions.get(session.id) !== session) return;
    this.push("_baya/session_changed", { session: session.info() });
  }

  // ── phones ──────────────────────────────────────────────────────────────

  connect(phone: HubPhone): void {
    this.phones.add(phone);
  }

  disconnect(phone: HubPhone): void {
    this.phones.delete(phone);
    for (const session of this.sessions.values()) session.detach(phone);
  }

  get connectedPhones(): number {
    return [...this.phones].filter((phone) => this.isPaired(phone.key)).length;
  }

  isPaired(key: string): boolean {
    return isPairedKey(key, this.peers);
  }

  /** Re-reads pairings after one was added or revoked; revoked phones are cut off. */
  async refreshPeers(): Promise<void> {
    this.peers = await listPeers();
    for (const phone of [...this.phones]) {
      if (phone.ready && !this.isPaired(phone.key)) {
        this.disconnect(phone);
        phone.close(CLOSE_UNPAIRED, "unpaired");
      }
    }
  }

  private push(method: string, params: Record<string, unknown>): void {
    for (const phone of this.phones) {
      if (phone.ready && this.isPaired(phone.key)) phone.notify(method, params);
    }
  }
}
