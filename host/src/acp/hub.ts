import { homedir } from "node:os";
import { type AgentDefinition, defaultAgentId, loadConfig } from "../config.ts";
import { type HerdrApp, herdrApp } from "../herdr/app.ts";
import { PaneSession, paneSessionId } from "../herdr/pane_session.ts";
import { isPairedKey, listPeers, markSeen, type PeerRecord } from "../pairing/storage.ts";
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

/** How many of the agents' own conversations the phone is shown, at most. */
const COMPUTER_SESSIONS = 200;

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("did not answer in time")), ms);
  });
  return Promise.race([work, late]).finally(() => clearTimeout(timer));
}

const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/**
 * Every session on this computer and every connected phone. Sessions load
 * from the registry at start; their agents start only when used.
 */
export class SessionHub {
  private readonly sessions = new Map<string, HostedSession>();
  /** Agents running in herdr panes, each a conversation of its own. */
  private readonly panes = new Map<string, PaneSession>();
  private paneTimer: NodeJS.Timeout | undefined;
  private readonly phones = new Set<HubPhone>();
  private peers: PeerRecord[] = [];
  private readonly persist: boolean;

  /** Follows herdr's panes (the host does; tests don't). */
  private readonly followPanes: boolean;

  constructor(options: { persist?: boolean; panes?: boolean } = {}) {
    this.persist = options.persist ?? true;
    this.followPanes = options.panes ?? false;
  }

  async start(): Promise<void> {
    this.peers = await listPeers();
    for (const record of listSessions()) this.adopt(record);
    if (this.followPanes) void this.watchPanes(true);
  }

  // ── herdr panes ─────────────────────────────────────────────────────────

  /**
   * Follows the agents in herdr's panes: each is a conversation, appearing,
   * changing and going away with its pane. herdr is asked every 2 s (every
   * 10 s while it isn't running).
   */
  private async watchPanes(first = false): Promise<void> {
    let running = true;
    try {
      if (first) await installIntegrations(herdrApp);
      const agents = await herdrApp.agents();
      const live = new Set<string>();
      for (const pane of agents) {
        const id = paneSessionId(pane.paneId);
        live.add(id);
        const known = this.panes.get(id);
        if (known) {
          known.update(pane);
        } else {
          const session = new PaneSession(pane, herdrApp, (changed) => this.paneChanged(changed));
          this.panes.set(id, session);
          this.paneChanged(session);
        }
      }
      for (const [id, session] of this.panes) {
        if (live.has(id)) continue;
        this.panes.delete(id);
        session.destroy();
        this.push("_baya/session_removed", { sessionId: id });
      }
    } catch {
      running = false;
    }
    clearTimeout(this.paneTimer);
    this.paneTimer = setTimeout(() => void this.watchPanes(), running ? 2_000 : 10_000);
    this.paneTimer.unref();
  }

  private paneChanged(session: PaneSession): void {
    if (this.panes.get(session.id) !== session) return;
    this.push("_baya/session_changed", { session: session.info() });
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

  list(cwd?: string): Conversation[] {
    return [...this.sessions.values(), ...this.panes.values()]
      .filter((session) => !cwd || session.record.cwd === cwd)
      .toSorted((a, b) => b.record.updatedAt - a.record.updatedAt);
  }

  get(id: string): Conversation | undefined {
    return this.sessions.get(id) ?? this.panes.get(id);
  }

  /** A conversation Baya runs itself (not one in a herdr pane). */
  hosted(id: string): HostedSession | undefined {
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
    clearTimeout(this.paneTimer);
    for (const session of this.sessions.values()) session.stop();
    for (const session of this.panes.values()) session.stop();
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
   * Every agent's own conversations on this computer, in any folder, that
   * Baya has not adopted: started in a terminal, an editor or anywhere else.
   * Newest first; an agent that cannot list, or fails to, is named in
   * `failed` and the others still answer.
   */
  async computerSessions(): Promise<Json> {
    const adopted = new Set(
      [...this.sessions.values()].map(
        (session) => `${session.record.agent}\n${session.record.agentSessionId}`,
      ),
    );
    const agents = (await this.agents()).filter((agent) => agent.available);
    const failed: Json[] = [];
    const lists = await Promise.all(
      agents.map(async (agent) => {
        try {
          return await withTimeout(
            this.withAgent(agent.id, undefined, async (process, info) => {
              if (!info.agentCapabilities?.sessionCapabilities?.list) return [];
              const sessions: Json[] = [];
              let cursor: unknown;
              // A few pages are plenty to find a recent conversation.
              for (let page = 0; page < 5 && sessions.length < COMPUTER_SESSIONS; page++) {
                const listed = await process.request<{ sessions?: Json[]; nextCursor?: unknown }>(
                  "session/list",
                  cursor === undefined ? {} : { cursor },
                );
                sessions.push(...(listed.sessions ?? []));
                cursor = listed.nextCursor;
                if (typeof cursor !== "string" || !cursor) break;
              }
              return sessions.flatMap((session) => {
                const id = session["sessionId"];
                const cwd = session["cwd"];
                if (typeof id !== "string" || typeof cwd !== "string") return [];
                if (adopted.has(`${agent.id}\n${id}`)) return [];
                return [
                  {
                    sessionId: id,
                    cwd,
                    title: typeof session["title"] === "string" ? session["title"] : "",
                    updatedAt:
                      typeof session["updatedAt"] === "string" ? session["updatedAt"] : null,
                    agent: agent.id,
                    agentName: agent.name,
                  },
                ];
              });
            }),
            60_000,
          );
        } catch (error) {
          failed.push({ agent: agent.id, agentName: agent.name, error: errorMessage(error) });
          return [];
        }
      }),
    );
    const sessions = lists
      .flat()
      .toSorted((a, b) => String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? "")))
      .slice(0, COMPUTER_SESSIONS);
    return { sessions, failed };
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
    for (const session of this.panes.values()) session.detach(phone);
    this.seen(phone.key);
  }

  /** A paired phone said hello (with the name it goes by) or left. */
  seen(key: string, name?: string): void {
    if (!this.isPaired(key)) return;
    markSeen(key, name).catch(() => {});
  }

  /**
   * Keys of the paired phones connected now. A phone counts once, even while
   * a reconnect briefly overlaps the socket it replaces.
   */
  connectedKeys(): Set<string> {
    const keys = new Set<string>();
    for (const phone of this.phones) {
      if (this.isPaired(phone.key)) keys.add(phone.key);
    }
    return keys;
  }

  get connectedPhones(): number {
    return this.connectedKeys().size;
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

/** A conversation the phone can open: Baya's own, or an agent in a herdr pane. */
export type Conversation = HostedSession | PaneSession;

/**
 * herdr's integrations for the agents Baya reads (hooks that tell herdr
 * which conversation each pane holds), installed once where missing.
 */
async function installIntegrations(app: HerdrApp): Promise<void> {
  const list = await app.call("integration.list", {});
  const integrations = (list["integrations"] as Record<string, unknown>[] | undefined) ?? [];
  for (const target of ["claude", "codex", "pi"]) {
    const entry = integrations.find((i) => i["target"] === target);
    // Not listed (the CLI on Windows lists none): install anyway, it is
    // idempotent; listed: only where the agent is there and it is missing.
    if (entry && (entry["available"] !== true || entry["state"] !== "not_installed")) continue;
    await app.call("integration.install", { target }).catch(() => {});
  }
}
