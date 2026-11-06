import { homedir } from "node:os";
import { type AgentDefinition, defaultAgentId, loadConfig } from "../config.ts";
import { isPairedKey, listPeers, type PeerRecord } from "../pairing/storage.ts";
import {
  addSession,
  listSessions,
  removeSession,
  type SessionRecord,
  type TitleSource,
} from "../session/registry.ts";
import { findExecutable } from "../workspace/directories.ts";
import { AgentProcess } from "./agent_process.ts";
import { HostedSession, type PhoneLink } from "./hosted_session.ts";
import { type Json, RpcError } from "./jsonrpc.ts";
import type { InitializeResponse } from "./schema.ts";

interface AgentInfo {
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

const CLOSE_UNPAIRED = 4003;

/**
 * Every session on this computer and every connected phone. Sessions load
 * from the registry at start; their agents start only when used.
 */
/**
 * The key of a terminal on this computer (`baya attach`), which reaches the
 * host through the control socket. Phone keys are base64 public keys, so
 * none can be this.
 */
export const LOCAL_CLIENT = "local";

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

  create(
    cwd: string,
    agent?: string,
    options: { title?: string; titleSource?: TitleSource; agentSessionId?: string } = {},
  ): HostedSession {
    const id = agent ?? defaultAgentId();
    if (!id) throw new Error("No agent is set up on this computer. Add one: baya agents add");
    if (!this.definition(id)) throw new Error(`No agent named "${id}" is set up on this computer.`);
    const session = this.adopt(addSession({ cwd, agent: id, ...options }));
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

  // ── an agent outside any session: sign-in and its own sessions ──────────

  /**
   * Runs [work] against a short-lived process of agent [id], for what
   * belongs to the agent rather than one Baya session.
   */
  async withAgent<T>(
    id: unknown,
    cwd: string | undefined,
    work: (agent: AgentProcess, info: InitializeResponse) => Promise<T>,
  ): Promise<T> {
    const definition = typeof id === "string" ? this.definition(id) : null;
    if (!definition) throw RpcError.invalidParams(`No agent named "${String(id)}" is set up.`);
    const agent = new AgentProcess(definition);
    try {
      const info = await agent.start(cwd ?? homedir(), {
        onRequest: (method) => Promise.reject(RpcError.methodNotFound(method)),
        onNotification: () => {},
        onExit: () => {},
      });
      return await work(agent, info);
    } finally {
      agent.stop();
    }
  }

  /** How the agent signs in, and whether it can sign out. */
  agentAuth(id: unknown): Promise<Json> {
    return this.withAgent(id, undefined, async (_, info) => ({
      authMethods: info.authMethods ?? [],
      logout: Boolean(
        (info.agentCapabilities as Json | undefined)?.["auth"] &&
          ((info.agentCapabilities as Json)["auth"] as Json)["logout"],
      ),
    }));
  }

  authenticate(id: unknown, methodId: unknown): Promise<Json> {
    if (typeof methodId !== "string") throw RpcError.invalidParams("methodId is required.");
    return this.withAgent(id, undefined, async (agent) => {
      await agent.request("authenticate", { methodId });
      this.restartAgent(String(id));
      return {};
    });
  }

  logout(id: unknown): Promise<Json> {
    return this.withAgent(id, undefined, async (agent) => {
      await agent.request("logout", {});
      this.restartAgent(String(id));
      return {};
    });
  }

  /** The agent's own conversations in [cwd] that Baya has not adopted. */
  agentSessions(id: unknown, cwd: string): Promise<Json> {
    return this.withAgent(id, cwd, async (agent, info) => {
      if (!info.agentCapabilities?.sessionCapabilities?.list) return { sessions: [] };
      const adopted = new Set(
        [...this.sessions.values()].map((session) => session.record.agentSessionId),
      );
      const listed = await agent.request<{ sessions?: Json[] }>("session/list", { cwd });
      return {
        sessions: (listed.sessions ?? []).filter(
          (session) =>
            typeof session["sessionId"] === "string" && !adopted.has(session["sessionId"]),
        ),
      };
    });
  }

  /**
   * The agent's copy of [source]'s conversation up to [point], an agent
   * message (ACP's `session/fork` with the JetBrains AIR fork point Claude
   * Code and Codex read). It runs in a process of its own that exits after,
   * so nothing holds the branch open when its session loads it: Codex lets
   * one process write a conversation at a time.
   */
  fork(
    source: HostedSession,
    point: { messageId: string; messageFingerprint?: string; messageOccurrence?: number },
  ): Promise<string> {
    const { agent: id, cwd, agentSessionId } = source.record;
    return this.withAgent(id, cwd, async (agent, info) => {
      const caps = info.agentCapabilities?.sessionCapabilities as Json | undefined;
      if (!caps?.["fork"] || !agentSessionId) {
        throw RpcError.invalidParams(`${agent.definition.name} cannot branch this conversation.`);
      }
      const forked = await agent.request<{ sessionId?: unknown }>("session/fork", {
        sessionId: agentSessionId,
        cwd,
        mcpServers: agent.definition.mcpServers ?? [],
        _meta: { jetbrains: { air: { fork: { version: 1, ...point } } } },
      });
      if (typeof forked?.sessionId !== "string") {
        throw new Error(`${agent.definition.name} did not branch.`);
      }
      return forked.sessionId;
    });
  }

  /** Running sessions of agent [id] pick up new sign-in state on next use. */
  private restartAgent(id: string): void {
    for (const session of this.sessions.values()) {
      if (session.record.agent === id && !session.working) session.stop();
    }
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
    return [...this.phones].filter(
      (phone) => phone.key !== LOCAL_CLIENT && this.isPaired(phone.key),
    ).length;
  }

  /** A paired phone, or `baya attach` on this computer (the control socket). */
  isPaired(key: string): boolean {
    return key === LOCAL_CLIENT || isPairedKey(key, this.peers);
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
