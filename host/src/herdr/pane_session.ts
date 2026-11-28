/**
 * A conversation that lives in a herdr pane: the agent runs there in its
 * own TUI, the one and only process. The phone's chat is that agent's own
 * record, read as it grows; what the phone sends is typed into the pane.
 * So the chat and the terminal are two views of one conversation.
 */
import { unwatchFile, watchFile } from "node:fs";
import { type Json, RpcError } from "../acp/jsonrpc.ts";
import type { PhoneLink } from "../acp/phone_link.ts";
import { BAYA_META, type PromptResponse } from "../acp/schema.ts";
import type { SessionRecord } from "../session/registry.ts";
import { folderName } from "../session/registry.ts";
import type { PaneAgent, PaneHost } from "./app.ts";
import {
  offers,
  optionCommand,
  paneOptions,
  paneOptionsLater,
  piContext,
  withCurrent,
} from "./models.ts";
import {
  agentFamily,
  locateRecord,
  type RecordUsage,
  readRecord,
  recordsIn,
  type Update,
} from "./records.ts";

/** How much of a long conversation a phone is sent when it opens it. */
const REPLAY = 800;

/** How an agent herdr recognizes is named to a person. */
function agentLabel(agent: string): string {
  switch (agentFamily(agent)) {
    case "claude":
      return "Claude Code";
    case "codex":
      return "Codex";
    case "pi":
      return "Pi";
    default:
      return agent;
  }
}

/** Baya's id for the conversation in [paneId]. */
export const paneSessionId = (paneId: string): string => `herdr-${paneId.replace(":", "-")}`;

export class PaneSession {
  private pane: PaneAgent;
  private readonly app: PaneHost;
  private readonly onChange: (session: PaneSession) => void;
  private readonly attached = new Set<PhoneLink>();
  private recordPath: string | null = null;
  private sent = 0;
  private recordTitle: string | null = null;
  private updatedAt = Date.now();
  /** Prompts typed in that its record doesn't show yet: queued in its TUI. */
  private queued: { id: string; text: string }[] = [];
  /** Settings picked from a phone (model, thinking), by option id. */
  private chosen: Record<string, string> = {};
  /** How full its context is, as its record last said. */
  private usage: Update | null = null;
  /** The model its record says last replied (Pi names it as its picker does). */
  private recordModel: string | null = null;
  /** Prompts waiting for the agent to finish the turn they started. */
  private readonly waiting: ((response: PromptResponse) => void)[] = [];
  /** The turn the phone started: when, what the record held, whether it was seen working. */
  private turn: { at: number; sent: number; sawWorking: boolean; timer: NodeJS.Timeout } | null =
    null;

  /** Started by Baya just now: no record older than this is its own. */
  private readonly since: number;

  /** The id the phone knows it by, for a conversation Baya ran before. */
  private readonly fixedId: string | undefined;
  /** The agent's own id of the conversation, known before its integration says. */
  private readonly knownRecord: string | undefined;

  constructor(
    pane: PaneAgent,
    app: PaneHost,
    onChange: (session: PaneSession) => void,
    since = 0,
    known: { id?: string; record?: string } = {},
  ) {
    this.since = since;
    this.fixedId = known.id;
    this.knownRecord = known.record;
    this.pane = pane;
    this.app = app;
    this.onChange = onChange;
    this.locate();
  }

  get id(): string {
    return this.fixedId ?? paneSessionId(this.pane.paneId);
  }

  get paneId(): string {
    return this.pane.paneId;
  }

  get working(): boolean {
    return this.pane.status === "working";
  }

  /** It waits for an answer in its TUI: an approval or a question. */
  get blocked(): boolean {
    return this.pane.status === "blocked";
  }

  get title(): string {
    return this.recordTitle || this.pane.title || folderName(this.pane.cwd);
  }

  /** What the rest of the host reads of a session. */
  get record(): SessionRecord {
    return {
      id: this.id,
      cwd: this.pane.cwd,
      agent: this.pane.agent,
      title: this.title,
      titleSource: "agent",
      agentSessionId: this.agentSessionId,
      createdAt: this.updatedAt,
      updatedAt: this.updatedAt,
    };
  }

  get agentSessionId(): string | null {
    const session = this.pane.session;
    if (session?.kind === "id") return session.value;
    const path = this.recordPath ?? session?.value;
    return path
      ? (path.split(/[\\/]/u).pop() ?? "")
          .replace(/\.jsonl$/u, "")
          .split("_")
          .pop() || null
      : null;
  }

  info(): Json {
    return {
      sessionId: this.id,
      cwd: this.pane.cwd,
      title: this.title,
      updatedAt: new Date(this.updatedAt).toISOString(),
      _meta: {
        [BAYA_META]: {
          agent: this.pane.agent,
          agentName: agentLabel(this.pane.agent),
          working: this.working,
          running: true,
          herdr: {
            pane: this.pane.paneId,
            status: this.pane.status,
            workspace: this.pane.workspace,
          },
        },
      },
    };
  }

  /** herdr reported the pane again: its status, title, session. */
  update(pane: PaneAgent): void {
    const before = JSON.stringify([
      this.pane.status,
      this.pane.title,
      this.pane.session,
      this.pane.workspace,
    ]);
    const wasWorking = this.working || this.pane.status === "blocked";
    this.pane = pane;
    if (this.turn && (this.working || this.blocked)) this.turn.sawWorking = true;
    if (JSON.stringify([pane.status, pane.title, pane.session, pane.workspace]) === before) return;
    this.updatedAt = Date.now();
    if (!this.recordPath || pane.session) {
      const before = this.recordPath;
      this.locate();
      // Its record appeared (a new conversation's first turn): follow it.
      if (this.recordPath !== before && this.attached.size > 0) {
        this.watch();
        this.read();
      }
    }
    // A turn the phone started has ended: its prompt is answered.
    if (wasWorking && (pane.status === "idle" || pane.status === "done")) this.endTurn();
    this.onChange(this);
  }

  // ── phone-facing ACP ────────────────────────────────────────────────────

  async attach(phone: PhoneLink, replay: boolean, _resume?: unknown): Promise<Json> {
    this.attached.add(phone);
    this.locate();
    if (replay) {
      const { updates } = this.load();
      for (const update of updates.slice(-REPLAY)) this.send(phone, update);
      this.sent = updates.length;
    }
    if (!replay) this.load();
    if (this.usage) this.send(phone, this.usage);
    this.watch();
    const options = paneOptions(this.pane.agent);
    // Still being asked of the agent: sent once it answers.
    if (options === null) {
      void paneOptionsLater(this.pane.agent).then((later) => {
        if (!later.length || !this.attached.has(phone)) return;
        this.send(phone, {
          sessionUpdate: "config_option_update",
          configOptions: this.current(later),
        } as Update);
      });
    }
    return {
      ...(options?.length ? { configOptions: this.current(options) } : {}),
      _meta: {
        [BAYA_META]: {
          agent: this.pane.agent,
          agentName: agentLabel(this.pane.agent),
          title: this.title,
          working: this.working,
          herdr: {
            pane: this.pane.paneId,
            status: this.pane.status,
            workspace: this.pane.workspace,
          },
          promptCapabilities: {},
          ...(this.queued.length ? { queued: this.queued } : {}),
          canFork: false,
        },
      },
    };
  }

  detach(phone: PhoneLink): void {
    this.attached.delete(phone);
    if (this.attached.size === 0 && this.recordPath) unwatchFile(this.recordPath);
  }

  isAttached(phone: PhoneLink): boolean {
    return this.attached.has(phone);
  }

  /** Typed into the agent in its pane; answered when its turn ends. */
  async prompt(phone: PhoneLink, params: Json): Promise<PromptResponse> {
    const blocks = Array.isArray(params["prompt"]) ? (params["prompt"] as Json[]) : [];
    const text = blocks
      .map((block) =>
        block["type"] === "text" && typeof block["text"] === "string"
          ? block["text"]
          : block["type"] === "resource_link" && typeof block["uri"] === "string"
            ? `@${String(block["uri"]).replace(/^file:\/\//u, "")}`
            : "",
      )
      .filter(Boolean)
      .join("\n");
    if (!text.trim()) throw RpcError.invalidParams("The prompt is empty.");
    this.attached.add(phone);
    if (this.blocked) {
      throw RpcError.invalidParams(
        "The agent is waiting for an answer in its terminal. Open the terminal to answer it.",
      );
    }
    const meta = (params["_meta"] as Json | undefined)?.[BAYA_META] as Json | undefined;
    const messageId = typeof meta?.["messageId"] === "string" ? meta["messageId"] : null;
    if (messageId) this.queued.push({ id: messageId, text });
    await this.app.prompt(this.pane.paneId, text);
    this.watch();
    this.startTurn();
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  /**
   * Follows the turn just typed in. herdr's status is read every couple of
   * seconds, so a quick turn may never be seen working: it is also over
   * once the agent is not working and its record has its reply, or, seen
   * neither way, half a minute on.
   */
  private startTurn(): void {
    if (this.turn) return;
    const turn = {
      at: Date.now(),
      sent: this.sent,
      sawWorking: this.working,
      timer: setInterval(() => {
        if (this.working || this.blocked) {
          turn.sawWorking = true;
          return;
        }
        this.read();
        const answered = this.sent >= turn.sent + 2 && Date.now() - turn.at > 3000;
        if (turn.sawWorking || answered || Date.now() - turn.at > 30_000) this.endTurn();
      }, 1500),
    };
    turn.timer.unref?.();
    this.turn = turn;
  }

  private endTurn(): void {
    if (this.turn) clearInterval(this.turn.timer);
    this.turn = null;
    this.read();
    for (const resolve of this.waiting.splice(0)) resolve({ stopReason: "end_turn" });
  }

  /** What its pane shows now. */
  screen(): Promise<{ text: string; rows: number }> {
    return this.app.screen(this.pane.paneId);
  }

  /** herdr-core's terminal it runs in, to stream to the phone; null for herdr's own panes. */
  terminal(): Promise<Record<string, unknown> | null> {
    return this.app.terminal(this.pane.paneId);
  }

  /** Types [text] (no Enter), then presses [keys], into its pane. */
  async input(text: string | undefined, keys: string[]): Promise<void> {
    if (text) await this.app.sendText(this.pane.paneId, text);
    if (keys.length) await this.app.sendKeys(this.pane.paneId, keys);
  }

  /** Ends its agent and closes its pane on the computer. */
  close(): Promise<void> {
    this.stop();
    return this.app.close(this.pane.paneId);
  }

  /** Esc, as its TUI stops a turn. */
  cancel(): void {
    void this.app.sendKeys(this.pane.paneId, ["esc"]).catch(() => {});
  }

  /** Its options with what was picked here, or its record says, as current. */
  private current(options: Json[]): Json[] {
    return withCurrent(options, {
      ...(this.recordModel ? { model: this.recordModel } : {}),
      ...this.chosen,
    });
  }

  /**
   * A model or thinking level picked on the phone: typed into its TUI as
   * the agent's own command (`/model`, `/effort`, `/thinking`).
   */
  async setConfigOption(_phone: PhoneLink, params: Json): Promise<Json> {
    const id = params["configId"];
    const value = params["value"];
    const options = await paneOptionsLater(this.pane.agent);
    const option = options.find((o) => o["id"] === id);
    const command =
      option && typeof value === "string" && value && offers(option, value)
        ? optionCommand(this.pane.agent, option, value)
        : null;
    if (!option || typeof value !== "string" || !command) {
      throw RpcError.invalidParams("This agent runs in herdr: change that in its terminal.");
    }
    if (this.working || this.pane.status === "blocked") {
      throw RpcError.invalidParams("Change it once its turn is over.");
    }
    await this.app.prompt(this.pane.paneId, command);
    this.chosen[String(id)] = value;
    const configOptions = this.current(options);
    for (const phone of this.attached)
      this.send(phone, { sessionUpdate: "config_option_update", configOptions } as Update);
    return { configOptions };
  }

  setMode(phone: PhoneLink, params: Json): Promise<Json> {
    return this.setConfigOption(phone, params);
  }

  rename(_title: string): void {}

  stop(): void {
    if (this.turn) clearInterval(this.turn.timer);
    if (this.recordPath) unwatchFile(this.recordPath);
  }

  destroy(): void {
    this.stop();
  }

  // ── the record ──────────────────────────────────────────────────────────

  /** Finds the agent's record: where its integration said, else the newest in its folder. */
  private locate(): void {
    const session = this.pane.session;
    let path: string | null = null;
    if (session?.kind === "path") path = session.value;
    else if (session?.kind === "id")
      path = locateRecord(this.pane.agent, session.value, this.pane.cwd);
    else if (this.knownRecord)
      path = locateRecord(this.pane.agent, this.knownRecord, this.pane.cwd);
    else if (agentFamily(this.pane.agent)) {
      // A pane Baya just started owns no record older than itself.
      const newest = recordsIn(this.pane.agent, this.pane.cwd)[0];
      path = newest && newest.at >= this.since ? newest.path : null;
    }
    if (path && path !== this.recordPath) {
      if (this.recordPath) unwatchFile(this.recordPath);
      this.recordPath = path;
      this.sent = 0;
    }
  }

  private load(): { updates: Update[]; title: string | null } {
    if (!this.recordPath) return { updates: [], title: null };
    const result = readRecord(this.pane.agent, this.recordPath);
    if (result.title) this.recordTitle = result.title;
    this.usage = this.usageUpdate(result.usage ?? null) ?? this.usage;
    if (this.queued.length) {
      const said = new Set(
        result.updates.flatMap((u) => {
          const content = u["content"] as Json | undefined;
          return u["sessionUpdate"] === "user_message_chunk" &&
            typeof content?.["text"] === "string"
            ? [content["text"].trim()]
            : [];
        }),
      );
      this.queued = this.queued.filter((q) => !said.has(q.text.trim()));
    }
    if (result.usage?.model) this.recordModel = result.usage.model;
    return result;
  }

  /** The phone's context ring: `usage_update` from the record's last reply. */
  private usageUpdate(usage: RecordUsage | null): Update | null {
    if (!usage || usage.used <= 0) return null;
    const size = usage.size || piContext(usage.model);
    if (!size) return null;
    return { sessionUpdate: "usage_update", used: usage.used, size } as Update;
  }

  private watch(): void {
    const path = this.recordPath;
    if (!path || this.attached.size === 0) return;
    unwatchFile(path);
    watchFile(path, { interval: 500 }, () => this.read());
  }

  /** What the agent wrote since: sent to every phone watching. */
  private read(): void {
    const before = JSON.stringify(this.usage);
    const { updates } = this.load();
    if (this.usage && JSON.stringify(this.usage) !== before) {
      for (const phone of this.attached) this.send(phone, this.usage);
    }
    if (updates.length <= this.sent) return;
    const fresh = updates.slice(this.sent);
    // Taken by the agent: in its record now, no longer queued.
    for (const update of fresh) {
      const content = update["content"] as Json | undefined;
      if (
        update["sessionUpdate"] !== "user_message_chunk" ||
        typeof content?.["text"] !== "string"
      ) {
        continue;
      }
      const said = content["text"].trim();
      const at = this.queued.findIndex((q) => q.text.trim() === said);
      if (at >= 0) this.queued.splice(at, 1);
    }
    this.sent = updates.length;
    this.updatedAt = Date.now();
    for (const phone of this.attached) {
      for (const update of fresh) this.send(phone, update);
    }
  }

  private send(phone: PhoneLink, update: Update): void {
    phone.notify("session/update", { sessionId: this.id, update });
  }
}
