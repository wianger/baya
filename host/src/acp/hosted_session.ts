import { randomUUID } from "node:crypto";
import type { AgentDefinition } from "../config.ts";
import { dshDesktop, isDsh } from "../integrations/dsh_desktop.ts";
import { phoneMcpServers } from "../integrations/phone_tools.ts";
import {
  folderName,
  outranks,
  type SessionRecord,
  type TitleSource,
  transcriptPath,
  updateSession,
} from "../session/registry.ts";
import { generateTitle } from "../session/titles.ts";
import { AgentProcess } from "./agent_process.ts";
import { ClientServices, type TerminalSnapshot } from "./client_services.ts";
import { isObject, type Json, RpcError, type RpcId } from "./jsonrpc.ts";
import {
  BAYA_META,
  type ContentBlock,
  type InitializeResponse,
  type NewSessionResponse,
  type PromptResponse,
  type SessionSetup,
  type SessionUpdate,
} from "./schema.ts";
import { isConversationUpdate, slim, Transcript } from "./transcript.ts";

/** A phone attached to sessions; the hub owns one per connection. */
export interface PhoneLink {
  readonly key: string;
  notify(method: string, params: Json): void;
  /** Sends a request; `id` lets the caller withdraw it with `$/cancel_request`. */
  ask(method: string, params: Json): { id: RpcId; result: Promise<unknown> };
}

interface SessionEvents {
  /** Title, activity or running state changed. */
  changed(session: HostedSession): void;
}

interface QueuedPrompt {
  prompt: ContentBlock[];
  messageId: string;
  resolve: (response: PromptResponse) => void;
  reject: (error: Error) => void;
}

/** A question the agent asked (question or elicitation), open on phones. */
interface PendingQuestion {
  method: string;
  params: Json;
  agentRequestId: RpcId;
  asked: Map<PhoneLink, RpcId>;
  resolve: (result: unknown) => void;
}

const START_TIMEOUT_MS = 180_000;
const IDLE_STOP_MS = 20 * 60_000;
/** The answer for a question nobody will answer any more. */
function cancelled(question: { method: string }): Json {
  return question.method === "elicitation/create"
    ? { action: "cancel" }
    : { outcome: { outcome: "cancelled" } };
}

/**
 * One Baya session. Phones talk to it in ACP; it talks ACP to its agent
 * process, which runs only while someone uses the session.
 *
 * The transcript lives here, not in the agent, so every phone can replay it
 * with `session/load` whether or not the agent supports loading, and so
 * several phones see one conversation.
 */
/** How long the agent has to name a session itself before one is made. */
const NAME_AFTER_MS = Number(process.env["BAYA_NAME_AFTER_MS"]) || 8_000;
const NAME_ON_OPEN_MS = Number(process.env["BAYA_NAME_AFTER_MS"]) || 12_000;
/** Live notifications kept for phones that come back after a drop. */
const RESUME_LOG = 4_000;

/** Where a phone is in a session's live notifications. */
export interface Cursor {
  epoch: string;
  seq: number;
}

interface Logged {
  seq: number;
  method: string;
  params: Json;
  terminalId?: string | undefined;
}

export class HostedSession {
  record: SessionRecord;
  private readonly resolveAgent: () => AgentDefinition | null;
  private readonly events: SessionEvents;
  private readonly transcript: Transcript;

  private process: AgentProcess | null = null;
  private starting: Promise<AgentProcess> | null = null;
  private replaying = false;
  /** The agent is replaying a conversation Baya adopts and keeps. */
  private loadingHistory = false;
  private setup: SessionSetup = {};
  private commands: SessionUpdate | null = null;
  private usage: SessionUpdate | null = null;
  private readonly attached = new Set<PhoneLink>();
  private readonly queue: QueuedPrompt[] = [];
  private current: QueuedPrompt | null = null;
  private readonly questions = new Set<PendingQuestion>();
  private readonly services = new ClientServices({
    cwd: () => this.record.cwd,
    onTerminal: (snapshot) => this.onTerminal(snapshot),
  });
  private idleTimer: NodeJS.Timeout | null = null;
  private lastError: string | null = null;
  /**
   * Every live notification is numbered and kept for a while, so a phone
   * that drops off (screen off, network change) catches up with only what it
   * missed instead of replaying the whole conversation. A new epoch, as
   * after a restart, means numbers from before mean nothing.
   */
  private readonly epoch = randomUUID();
  private seq = 0;
  /** Notifications up to this number are no longer in [log]. */
  private floor = 0;
  private readonly log: Logged[] = [];

  constructor(
    record: SessionRecord,
    resolveAgent: () => AgentDefinition | null,
    events: SessionEvents,
    persist = true,
  ) {
    this.record = record;
    this.resolveAgent = resolveAgent;
    this.events = events;
    this.transcript = new Transcript(persist ? transcriptPath(record.id) : null);
  }

  get id(): string {
    return this.record.id;
  }

  get working(): boolean {
    return this.current !== null;
  }

  get running(): boolean {
    return this.process?.running === true;
  }

  get title(): string {
    return this.record.title ?? folderName(this.record.cwd);
  }

  /** ACP `SessionInfo` with Baya's additions. */
  info(): Json {
    return {
      sessionId: this.id,
      cwd: this.record.cwd,
      title: this.title,
      updatedAt: new Date(this.record.updatedAt).toISOString(),
      _meta: {
        [BAYA_META]: {
          agent: this.record.agent,
          agentName: this.agentName,
          working: this.working,
          running: this.running,
          ...(this.lastError ? { error: this.lastError } : {}),
        },
      },
    };
  }

  // ── phone-facing ACP ────────────────────────────────────────────────────

  /**
   * `session/new` and `session/load`: replays history to [phone] and attaches
   * it. A phone that brings a [resume] cursor this session can still serve
   * gets only the notifications after it.
   */
  async attach(phone: PhoneLink, replay: boolean, resume?: Cursor): Promise<Json> {
    await this.ensureAgent();
    // Named only by its first line so far: the agent may still name it as it
    // loads; if not, a short title is made.
    if (this.record.titleSource === "prompt" && this.record.title) {
      this.nameLater(this.record.title, NAME_ON_OPEN_MS);
    }
    const resumed =
      replay && resume?.epoch === this.epoch && resume.seq >= this.floor && resume.seq <= this.seq;
    if (resumed) {
      for (const entry of this.log) {
        if (entry.seq > resume.seq) phone.notify(entry.method, entry.params);
      }
    } else if (replay) {
      for (const update of this.transcript.updates) this.send(phone, update);
      for (const terminal of this.transcript.terminals) {
        phone.notify("_baya/terminal", { sessionId: this.id, ...terminal });
      }
    }
    if (this.commands) this.send(phone, this.commands);
    if (this.usage) this.send(phone, this.usage);
    this.attached.add(phone);
    this.cancelIdleStop();
    // Open questions go out after the load response, as live requests would.
    setImmediate(() => {
      for (const question of this.questions) this.askOne(question, phone);
    });
    // Where the phone now is, and whether it got a catch-up or the history.
    return this.setupResponse({ cursor: { epoch: this.epoch, seq: this.seq }, resumed });
  }

  detach(phone: PhoneLink): void {
    if (!this.attached.delete(phone)) return;
    for (const question of this.questions) question.asked.delete(phone);
    this.scheduleIdleStop();
  }

  isAttached(phone: PhoneLink): boolean {
    return this.attached.has(phone);
  }

  /** `session/prompt`; prompts sent while the agent works wait their turn. */
  prompt(phone: PhoneLink, params: Json): Promise<PromptResponse> {
    if (!Array.isArray(params["prompt"]) || params["prompt"].length === 0) {
      throw RpcError.invalidParams("The prompt is empty.");
    }
    const prompt = params["prompt"] as ContentBlock[];
    const caps = this.process?.info?.agentCapabilities?.promptCapabilities;
    if (prompt.some((block) => block.type === "image") && this.process?.info && !caps?.image) {
      throw RpcError.invalidParams(`${this.agentName} cannot read images.`);
    }
    const meta = bayaMeta(params);
    const messageId = typeof meta["messageId"] === "string" ? meta["messageId"] : randomUUID();
    this.attached.add(phone);
    return new Promise<PromptResponse>((resolve, reject) => {
      this.queue.push({ prompt, messageId, resolve, reject });
      void this.drain();
    });
  }

  /** `session/cancel`: stops the running turn and drops the queue. */
  cancel(): void {
    for (const queued of this.queue.splice(0)) queued.resolve({ stopReason: "cancelled" });
    for (const question of [...this.questions]) this.settleQuestion(question, cancelled(question));
    if (this.current && this.process && this.record.agentSessionId) {
      this.process.notify("session/cancel", { sessionId: this.record.agentSessionId });
    }
  }

  async setConfigOption(phone: PhoneLink, params: Json): Promise<Json> {
    const agent = await this.ensureAgent();
    const result = await agent.request<Json>("session/set_config_option", {
      ...params,
      sessionId: this.record.agentSessionId,
    });
    if (Array.isArray(result["configOptions"])) {
      this.setup.configOptions = result["configOptions"];
      this.broadcast(
        { sessionUpdate: "config_option_update", configOptions: result["configOptions"] },
        phone,
      );
    }
    return result;
  }

  async setMode(phone: PhoneLink, params: Json): Promise<Json> {
    const agent = await this.ensureAgent();
    const result = await agent.request<Json>("session/set_mode", {
      ...params,
      sessionId: this.record.agentSessionId,
    });
    if (typeof params["modeId"] === "string") {
      if (this.setup.modes) this.setup.modes.currentModeId = params["modeId"];
      this.broadcast(
        { sessionUpdate: "current_mode_update", currentModeId: params["modeId"] },
        phone,
      );
    }
    return result ?? {};
  }

  /** Stops the agent; the session and its history remain. */
  stop(): void {
    this.cancelIdleStop();
    this.cancel();
    for (const queued of this.queue.splice(0)) queued.reject(new Error("Baya stopped."));
    this.services.dispose();
    this.process?.stop();
    this.process = null;
    this.starting = null;
    this.transcript.flush();
  }

  /** Stops the agent and forgets the history. */
  destroy(): void {
    const agent = this.process;
    if (this.record.agentSessionId) dshDesktop.forget(this.record.agentSessionId);
    if (this.record.agentSessionId && agent?.info?.agentCapabilities?.sessionCapabilities?.delete) {
      void agent
        .request("session/delete", { sessionId: this.record.agentSessionId })
        .catch(() => {});
    }
    this.stop();
    this.transcript.destroy();
    this.attached.clear();
  }

  // ── agent lifecycle ─────────────────────────────────────────────────────

  private get agentName(): string {
    return this.process?.definition.name ?? this.resolveAgent()?.name ?? this.record.agent;
  }

  private ensureAgent(): Promise<AgentProcess> {
    if (this.process?.running) return Promise.resolve(this.process);
    this.starting ??= this.startAgent().then(
      (agent) => {
        this.starting = null;
        this.lastError = null;
        this.events.changed(this);
        return agent;
      },
      (error: unknown) => {
        this.starting = null;
        this.process?.stop();
        this.process = null;
        this.lastError = error instanceof Error ? error.message : String(error);
        this.events.changed(this);
        throw error;
      },
    );
    return this.starting;
  }

  private async startAgent(): Promise<AgentProcess> {
    const definition = this.resolveAgent();
    if (!definition) {
      throw new Error(
        `The agent "${this.record.agent}" is not set up on this computer. Add it: baya agents add`,
      );
    }
    const agent = new AgentProcess(definition);
    this.process = agent;
    const info = await withTimeout(
      agent.start(this.record.cwd, {
        onRequest: (method, params, id) => this.onAgentRequest(method, params, id),
        onNotification: (method, params) => this.onAgentNotification(method, params),
        onExit: (error) => this.onAgentExit(agent, error),
      }),
      START_TIMEOUT_MS,
      `${this.agentName} did not answer \`initialize\` in time.`,
    );
    this.setup = await this.openAgentSession(agent, info);
    return agent;
  }

  /** Reopens the agent's side of this conversation, or starts it. */
  private async openAgentSession(
    agent: AgentProcess,
    info: InitializeResponse,
  ): Promise<SessionSetup> {
    const cwd = this.record.cwd;
    const mcpServers = [...(agent.definition.mcpServers ?? []), ...(await phoneMcpServers())];
    const previous = this.record.agentSessionId;
    const caps = info.agentCapabilities;
    if (previous && (caps?.loadSession || caps?.sessionCapabilities?.resume)) {
      try {
        this.registerElsewhere(agent, previous);
        if (caps.loadSession) {
          // The agent replays its history. Baya keeps it only for a session
          // it adopted from the agent and has no history of yet.
          this.replaying = this.transcript.updates.length > 0;
          this.loadingHistory = !this.replaying;
          return (
            (await agent.request<SessionSetup>("session/load", {
              sessionId: previous,
              cwd,
              mcpServers,
            })) ?? {}
          );
        }
        return (
          (await agent.request<SessionSetup>("session/resume", {
            sessionId: previous,
            cwd,
            mcpServers,
          })) ?? {}
        );
      } catch (error) {
        if (!agent.running) throw error;
      } finally {
        this.replaying = false;
        this.loadingHistory = false;
      }
    }
    const created = await agent.request<NewSessionResponse>("session/new", { cwd, mcpServers });
    if (typeof created?.sessionId !== "string") {
      throw new Error(`${this.agentName} did not return a session id.`);
    }
    if (previous) {
      this.publish({
        sessionUpdate: "notice",
        severity: "warning",
        title: `${this.agentName} restarted without the earlier conversation.`,
      });
    }
    this.record = updateSession(this.id, { agentSessionId: created.sessionId }) ?? {
      ...this.record,
      agentSessionId: created.sessionId,
    };
    this.registerElsewhere(agent, created.sessionId);
    return created;
  }

  /** Makes the session show in the agent's own app where Baya knows how. */
  private registerElsewhere(agent: AgentProcess, agentSessionId: string): void {
    if (isDsh(agent.definition)) {
      dshDesktop.register(agent.definition, agentSessionId, this.record.cwd);
    }
  }

  private onAgentExit(agent: AgentProcess, error: Error): void {
    if (this.process !== agent) return;
    this.process = null;
    process.stderr.write(`[baya] ${this.title}: ${error.message}\n`);
    for (const question of [...this.questions]) this.settleQuestion(question, cancelled(question));
    this.events.changed(this);
  }

  private scheduleIdleStop(): void {
    if (this.attached.size > 0 || this.working || this.idleTimer) return;
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      if (this.attached.size > 0 || this.working || !this.process) return;
      this.process.stop();
      this.process = null;
      this.events.changed(this);
    }, IDLE_STOP_MS);
    this.idleTimer.unref();
  }

  private cancelIdleStop(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
  }

  // ── turns ───────────────────────────────────────────────────────────────

  private async drain(): Promise<void> {
    if (this.current) return;
    const next = this.queue.shift();
    if (!next) return;
    this.current = next;
    this.cancelIdleStop();
    this.events.changed(this);
    try {
      const agent = await this.ensureAgent();
      for (const content of next.prompt) {
        this.publish({ sessionUpdate: "user_message_chunk", content, messageId: next.messageId });
      }
      this.touch(next.prompt);
      const response = await agent.request<PromptResponse>("session/prompt", {
        sessionId: this.record.agentSessionId,
        prompt: next.prompt,
      });
      next.resolve(response);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      // ACP: -32000 from an agent means it needs a sign-in. Say which.
      const needsAuth = error instanceof RpcError && error.code === -32000;
      this.publish({
        sessionUpdate: "notice",
        severity: "error",
        title: message,
        ...(needsAuth ? { _meta: { [BAYA_META]: { authRequired: this.record.agent } } } : {}),
      });
      next.reject(
        needsAuth
          ? new RpcError(-32000, message, { reason: "auth_required", agent: this.record.agent })
          : error instanceof Error
            ? error
            : new Error(message),
      );
    } finally {
      this.current = null;
      this.events.changed(this);
      this.scheduleIdleStop();
      void this.drain();
    }
  }

  /**
   * The first prompt names an untitled session with its first line, until
   * the agent names it or, if it does not, a short title is generated.
   */
  private touch(prompt: ContentBlock[]): void {
    const patch: Partial<SessionRecord> = { updatedAt: Date.now() };
    if (this.record.title === null) {
      const text = prompt.find((block) => block.type === "text")?.["text"];
      const all = typeof text === "string" ? text.trim() : "";
      const line = all.split(/\r?\n/u)[0]?.trim() ?? "";
      if (line) {
        patch.title = line.length > 60 ? `${line.slice(0, 59)}…` : line;
        patch.titleSource = "prompt";
        this.nameLater(all, NAME_AFTER_MS);
      }
    }
    this.record = updateSession(this.id, patch) ?? { ...this.record, ...patch };
  }

  /** A person's name for the session, which nothing else replaces. */
  rename(title: string): void {
    const name = title.trim().slice(0, 120);
    if (!name) throw RpcError.invalidParams("A name is required.");
    this.setTitle(name, "user");
  }

  private setTitle(title: string, source: TitleSource): void {
    if (!outranks(source, this.record.titleSource)) return;
    if (title === this.record.title && source === this.record.titleSource) return;
    this.record = updateSession(this.id, { title, titleSource: source }) ?? {
      ...this.record,
      title,
      titleSource: source,
    };
    this.events.changed(this);
  }

  private naming = false;

  /**
   * After [delay], if the session still has only its first line for a name
   * (the agent gave none), asks for a short title.
   */
  private nameLater(text: string, delay: number): void {
    if (this.naming) return;
    this.naming = true;
    const timer = setTimeout(() => {
      void (async () => {
        try {
          if (this.record.titleSource !== "prompt") return;
          const title = await generateTitle(text);
          if (title && this.record.titleSource === "prompt") this.setTitle(title, "generated");
        } finally {
          this.naming = false;
        }
      })();
    }, delay);
    timer.unref?.();
  }

  // ── agent → phones ──────────────────────────────────────────────────────

  private onAgentNotification(method: string, params: Json): void {
    if (method === "$/cancel_request") {
      const question = [...this.questions].find(
        (entry) => entry.agentRequestId === params["requestId"],
      );
      if (question) this.settleQuestion(question, cancelled(question));
      return;
    }
    if (method === "elicitation/complete") {
      for (const phone of this.attached) phone.notify(method, params);
      return;
    }
    if (method !== "session/update" || !isObject(params["update"])) return;
    const update = params["update"] as SessionUpdate;
    if (typeof update.sessionUpdate !== "string") return;
    switch (update.sessionUpdate) {
      case "available_commands_update":
        this.commands = update;
        break;
      case "usage_update":
        this.usage = update;
        break;
      case "config_option_update":
        if (Array.isArray(update["configOptions"]))
          this.setup.configOptions = update["configOptions"];
        break;
      case "current_mode_update":
        if (this.setup.modes && typeof update["currentModeId"] === "string") {
          this.setup.modes.currentModeId = update["currentModeId"];
        }
        break;
      case "session_info_update":
        if (typeof update["title"] === "string" && update["title"].trim()) {
          this.setTitle(update["title"].trim(), "agent");
        }
        break;
      case "user_message_chunk":
        // Baya publishes prompts itself, as they leave the queue; only an
        // adopted conversation's history brings the user's messages.
        if (!this.loadingHistory) return;
        break;
      case "agent_message_chunk":
        // What the agent says on its own before the first prompt (its
        // version, loaded skills) is startup chatter, not a reply.
        if (!this.current && !this.loadingHistory && !this.prompted()) {
          const meta = isObject(update["_meta"]) ? update["_meta"] : {};
          const baya = isObject(meta["baya"]) ? meta["baya"] : {};
          update["_meta"] = { ...meta, baya: { ...baya, startup: true } };
        }
        break;
    }
    // A loading agent replays history Baya already holds.
    if (this.replaying && isConversationUpdate(update)) return;
    this.publish(update);
  }

  private prompted(): boolean {
    return this.transcript.updates.some((u) => u.sessionUpdate === "user_message_chunk");
  }

  private publish(update: SessionUpdate): void {
    const slimmed = slim(update);
    this.transcript.append(slimmed);
    this.broadcast(slimmed);
  }

  private broadcast(update: SessionUpdate, except?: PhoneLink): void {
    const params = this.number("session/update", { sessionId: this.id, update });
    for (const phone of this.attached) if (phone !== except) phone.notify("session/update", params);
  }

  /** Numbers a live notification and keeps it for phones that come back. */
  private number(method: string, params: Json, terminalId?: string): Json {
    const numbered = { ...params, _meta: { [BAYA_META]: { seq: ++this.seq } } };
    if (terminalId !== undefined) {
      // A terminal snapshot holds all its output: only the latest counts.
      const older = this.log.findLastIndex((entry) => entry.terminalId === terminalId);
      if (older !== -1) this.log.splice(older, 1);
    }
    this.log.push({ seq: this.seq, method, params: numbered, terminalId });
    if (this.log.length > RESUME_LOG) this.floor = this.log.shift()!.seq;
    return numbered;
  }

  private send(phone: PhoneLink, update: SessionUpdate): void {
    phone.notify("session/update", { sessionId: this.id, update });
  }

  private onAgentRequest(method: string, params: Json, id: RpcId): Promise<unknown> {
    if (ClientServices.handles(method)) return this.services.handle(method, params);
    if (method !== "session/request_permission" && method !== "elicitation/create") {
      return Promise.reject(RpcError.methodNotFound(method));
    }
    return new Promise((resolve) => {
      const question: PendingQuestion = {
        method,
        params: { ...params, ...(params["sessionId"] ? { sessionId: this.id } : {}) },
        agentRequestId: id,
        asked: new Map(),
        resolve,
      };
      this.questions.add(question);
      for (const phone of this.attached) this.askOne(question, phone);
    });
  }

  /** Asks one phone; the first answer from any phone settles it. */
  private askOne(question: PendingQuestion, phone: PhoneLink): void {
    if (!this.questions.has(question) || question.asked.has(phone)) return;
    const { id, result } = phone.ask(question.method, question.params);
    question.asked.set(phone, id);
    result.then(
      (answer) => {
        if (question.asked.get(phone) === id) question.asked.delete(phone);
        this.settleQuestion(question, answer);
      },
      () => {
        if (question.asked.get(phone) === id) question.asked.delete(phone);
      },
    );
  }

  private settleQuestion(question: PendingQuestion, answer: unknown): void {
    if (!this.questions.delete(question)) return;
    for (const [phone, requestId] of question.asked) {
      phone.notify("$/cancel_request", { requestId });
    }
    question.asked.clear();
    question.resolve(answer);
  }

  private onTerminal(snapshot: TerminalSnapshot): void {
    this.transcript.setTerminal(snapshot);
    const params = this.number(
      "_baya/terminal",
      { sessionId: this.id, ...snapshot },
      snapshot.terminalId,
    );
    for (const phone of this.attached) phone.notify("_baya/terminal", params);
  }

  private setupResponse(extra: Json = {}): Json {
    return {
      ...(this.setup.configOptions ? { configOptions: this.setup.configOptions } : {}),
      ...(this.setup.modes ? { modes: this.setup.modes } : {}),
      _meta: {
        [BAYA_META]: {
          agent: this.record.agent,
          agentName: this.agentName,
          title: this.title,
          working: this.working,
          promptCapabilities: this.process?.info?.agentCapabilities?.promptCapabilities ?? {},
          canFork: Boolean(
            (this.process?.info?.agentCapabilities?.sessionCapabilities as Json | undefined)?.[
              "fork"
            ],
          ),
          ...extra,
        },
      },
    };
  }
}

function bayaMeta(params: Json): Json {
  const meta = params["_meta"];
  if (!isObject(meta)) return {};
  const baya = meta[BAYA_META];
  return isObject(baya) ? baya : {};
}

function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
