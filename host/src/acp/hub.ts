import { homedir } from "node:os";
import { type AgentDefinition, defaultAgentId, loadConfig } from "../config.ts";
import { resumeArgs, sessionForPane, setSessionForPane } from "../herdr/aliases.ts";
import { herdrApp, type PaneAgent, type PaneHost } from "../herdr/app.ts";
import { isMirror, mirrorList, setMirror } from "../herdr/mirrors.ts";
import { useModelFetcher } from "../herdr/models.ts";
import { PaneSession, paneSessionId } from "../herdr/pane_session.ts";
import { locateRecord } from "../herdr/records.ts";
import { herdrWindow } from "../herdr/window.ts";
import { isPairedKey, listPeers, markSeen, type PeerRecord } from "../pairing/storage.ts";
import { findExecutable } from "../workspace/directories.ts";
import { AgentProcess } from "./agent_process.ts";
import { type Json, RpcError } from "./jsonrpc.ts";
import type { PhoneLink } from "./phone_link.ts";
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
 * Every conversation on this computer (an agent in herdr, each in its own
 * pane) and every connected phone.
 */
export class SessionHub {
  /** Agents running in herdr panes, each a conversation of its own. */
  private readonly panes = new Map<string, PaneSession>();
  private paneTimer: NodeJS.Timeout | undefined;
  private readonly phones = new Set<HubPhone>();
  private peers: PeerRecord[] = [];

  /** Follows herdr's panes (the host does; tests don't). */
  private readonly followPanes: boolean;
  /** What each mirror tab last told herdr, so it is told only changes. */
  private readonly mirrorStates = new Map<string, string>();

  constructor(options: { panes?: boolean } = {}) {
    this.followPanes = options.panes ?? false;
    // A pane's agent offers the models it gives Baya over ACP.
    if (this.followPanes) {
      useModelFetcher((id) => (this.definition(id) ? this.agentOptions(id) : Promise.resolve([])));
    }
  }

  async start(): Promise<void> {
    this.peers = await listPeers();
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
      if (first) await herdrApp.prepare().catch(() => {});
      // Agents run in two places: the herdr-app window (over herdr-core) and
      // herdr's server (its TUI). A tab that only mirrors a window agent in
      // the TUI is not a conversation of its own.
      const [inWindow, server] = await Promise.all([
        herdrWindow.agents().catch(() => null),
        herdrApp.list().catch(() => null),
      ]);
      if (!inWindow && !server) throw new Error("no herdr");
      if (inWindow && server) await this.syncMirrors(inWindow, server.ids);
      const agents: [PaneAgent, PaneHost][] = [
        ...(inWindow ?? []).map((pane): [PaneAgent, PaneHost] => [pane, herdrWindow]),
        ...(server?.agents ?? [])
          .filter((pane) => !isMirror(pane.paneId))
          .map((pane): [PaneAgent, PaneHost] => [pane, herdrApp]),
      ];
      const live = new Set<string>();
      for (const [pane, host] of agents) {
        // A conversation the phone knew by another id keeps it.
        const alias = sessionForPane(pane.paneId);
        const id = alias ?? paneSessionId(pane.paneId);
        live.add(id);
        const known = this.panes.get(id);
        if (known) {
          known.update(pane);
        } else {
          const session = new PaneSession(
            pane,
            host,
            (changed) => this.paneChanged(changed),
            0,
            alias ? { id: alias } : {},
          );
          this.panes.set(id, session);
          this.paneChanged(session);
        }
      }
      for (const [id, session] of this.panes) {
        if (live.has(id)) continue;
        this.panes.delete(id);
        session.destroy();
        setSessionForPane(session.paneId, null);
        this.push("_baya/session_removed", { sessionId: id });
      }
    } catch {
      running = false;
    }
    clearTimeout(this.paneTimer);
    this.paneTimer = setTimeout(() => void this.watchPanes(), running ? 2_000 : 10_000);
    this.paneTimer.unref();
  }

  /**
   * A new conversation as alma runs one: a tab in [cwd]'s herdr workspace
   * with [agent]'s own TUI started in it, visible on the computer, or
   * [resume] (one of the agent's own) reopened there. Null when herdr isn't
   * running or can't start that agent.
   */
  async startInPane(
    cwd: string,
    agent?: string,
    space?: string,
    resume?: string,
  ): Promise<PaneSession | null> {
    const id = agent ?? defaultAgentId();
    const kind = id ? HERDR_KINDS[id] : undefined;
    if (!this.followPanes || !kind || !id) return null;
    // One of the agent's own conversations, reopened in its TUI.
    const args = resume ? resumeArgs(id, resume, locateRecord(id, resume, cwd) !== null) : [];
    if (!args) return null;
    const since = resume ? 0 : Date.now();
    const started = await this.startAgent(kind, cwd, args, undefined, space);
    if (!started) return null;
    const { pane, host } = started;
    const session = new PaneSession(
      pane,
      host,
      (changed) => this.paneChanged(changed),
      since,
      resume ? { record: resume } : {},
    );
    this.panes.set(session.id, session);
    this.paneChanged(session);
    return session;
  }

  /**
   * Starts [kind] in [cwd]: in herdr-core, shown in the herdr-app window,
   * with a tab in herdr's TUI showing the same terminal; in herdr's server
   * alone where herdr-core isn't here. Null when neither is.
   */
  private async startAgent(
    kind: string,
    cwd: string,
    args: string[] = [],
    alias?: string,
    space?: string,
  ): Promise<{ pane: PaneAgent; host: PaneHost } | null> {
    if (await herdrWindow.available()) {
      const terminal = await herdrWindow.start(kind, cwd, args, space);
      if (alias) setSessionForPane(terminal, alias);
      if (await herdrApp.available()) {
        const mirror = await herdrApp.openMirror(cwd, terminal, kind, space).catch(() => null);
        if (mirror) setMirror(terminal, mirror);
      }
      const pane = (await herdrWindow.agents()).find((p) => p.paneId === terminal);
      return pane ? { pane, host: herdrWindow } : null;
    }
    if (!(await herdrApp.available())) return null;
    const paneId = await herdrApp.start(kind, cwd, args);
    if (alias) setSessionForPane(paneId, alias);
    const pane = (await herdrApp.agents()).find((p) => p.paneId === paneId);
    return pane ? { pane, host: herdrApp } : null;
  }

  /**
   * Keeps herdr's TUI tabs that mirror window agents in step: each shows
   * its agent's status there; a tab whose agent ended closes; a tab closed
   * by hand is forgotten (the agent stays in the window).
   */
  private async syncMirrors(inWindow: PaneAgent[], serverPanes: Set<string>): Promise<void> {
    for (const [terminal, mirror] of mirrorList()) {
      const agent = inWindow.find((p) => p.paneId === terminal);
      if (!serverPanes.has(mirror) || !agent) {
        if (!agent && serverPanes.has(mirror)) await herdrApp.closePane(mirror).catch(() => {});
        setMirror(terminal, null);
        this.mirrorStates.delete(mirror);
        continue;
      }
      const state = agent.status === "done" ? "idle" : agent.status;
      if (this.mirrorStates.get(mirror) === state) continue;
      const reported = await herdrApp
        .reportAgent(mirror, agent.agent, state, agent.session?.value)
        .then(() => true)
        .catch(() => false);
      if (reported) this.mirrorStates.set(mirror, state);
    }
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
    return [...this.panes.values()]
      .filter((session) => !cwd || session.record.cwd === cwd)
      .toSorted((a, b) => b.record.updatedAt - a.record.updatedAt);
  }

  get(id: string): Conversation | undefined {
    return this.panes.get(id);
  }

  /**
   * Closes a conversation: its agent ends and its tab or window pane
   * closes on the computer; the agent's own history stays.
   */
  async close(id: string): Promise<boolean> {
    const pane = this.panes.get(id);
    if (!pane) return false;
    await pane.close();
    this.panes.delete(id);
    this.push("_baya/session_removed", { sessionId: id });
    return true;
  }

  stop(): void {
    clearTimeout(this.paneTimer);
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

  /** Agent [id]'s settings (`configOptions`), from a session of it started for the asking. */
  agentOptions(id: string): Promise<Json[]> {
    return this.withAgent(id, undefined, async (agent) => {
      const result = (await agent.request("session/new", {
        cwd: homedir(),
        mcpServers: [],
      })) as Json;
      return Array.isArray(result["configOptions"]) ? (result["configOptions"] as Json[]) : [];
    });
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
      return {};
    });
  }

  logout(id: unknown): Promise<Json> {
    return this.withAgent(id, undefined, async (agent) => {
      await agent.request("logout", {});
      return {};
    });
  }

  /** The agent's own conversations in [cwd] not open in a pane already. */
  agentSessions(id: unknown, cwd: string): Promise<Json> {
    return this.withAgent(id, cwd, async (agent, info) => {
      if (!info.agentCapabilities?.sessionCapabilities?.list) return { sessions: [] };
      const adopted = new Set([...this.panes.values()].map((session) => session.agentSessionId));
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
   * Every agent's own conversations on this computer, in any folder, not
   * open in a pane already: started in a terminal, an editor or anywhere else.
   * Newest first; an agent that cannot list, or fails to, is named in
   * `failed` and the others still answer.
   */
  async computerSessions(): Promise<Json> {
    const adopted = new Set(
      [...this.panes.values()].map(
        (session) => `${session.record.agent}\n${session.agentSessionId}`,
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

  // ── phones ──────────────────────────────────────────────────────────────

  connect(phone: HubPhone): void {
    this.phones.add(phone);
  }

  disconnect(phone: HubPhone): void {
    this.phones.delete(phone);
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

/** Baya's agent ids → the kinds herdr starts and recognizes. */
const HERDR_KINDS: Record<string, string> = {
  claude: "claude",
  codex: "codex",
  pi: "pi",
  agy: "agy",
};

/** A conversation the phone can open: an agent in a herdr pane. */
export type Conversation = PaneSession;
