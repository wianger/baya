/**
 * A conversation that lives in a herdr pane: the agent runs there in its
 * own TUI, the one and only process. The phone's chat is that agent's own
 * record, read as it grows; what the phone sends is typed into the pane.
 * So the chat and the terminal are two views of one conversation.
 */
import { unwatchFile, watchFile } from "node:fs";
import type { PhoneLink } from "../acp/hosted_session.ts";
import { type Json, RpcError } from "../acp/jsonrpc.ts";
import { BAYA_META, type PromptResponse } from "../acp/schema.ts";
import type { SessionRecord } from "../session/registry.ts";
import { folderName } from "../session/registry.ts";
import type { HerdrApp, PaneAgent } from "./app.ts";
import { agentFamily, locateRecord, readRecord, recordsIn, type Update } from "./records.ts";

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
  private readonly app: HerdrApp;
  private readonly onChange: (session: PaneSession) => void;
  private readonly attached = new Set<PhoneLink>();
  private recordPath: string | null = null;
  private sent = 0;
  private recordTitle: string | null = null;
  private updatedAt = Date.now();
  /** Prompts waiting for the agent to finish the turn they started. */
  private readonly waiting: ((response: PromptResponse) => void)[] = [];

  /** Started by Baya just now: no record older than this is its own. */
  private readonly since: number;

  /** The id the phone knows it by, for a conversation Baya ran before. */
  private readonly fixedId: string | undefined;
  /** The agent's own id of the conversation, known before its integration says. */
  private readonly knownRecord: string | undefined;

  constructor(
    pane: PaneAgent,
    app: HerdrApp,
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
          herdr: { pane: this.pane.paneId, status: this.pane.status },
        },
      },
    };
  }

  /** herdr reported the pane again: its status, title, session. */
  update(pane: PaneAgent): void {
    const before = JSON.stringify([this.pane.status, this.pane.title, this.pane.session]);
    const wasWorking = this.working || this.pane.status === "blocked";
    this.pane = pane;
    if (JSON.stringify([pane.status, pane.title, pane.session]) === before) return;
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
    if (wasWorking && (pane.status === "idle" || pane.status === "done")) {
      this.read();
      for (const resolve of this.waiting.splice(0)) resolve({ stopReason: "end_turn" });
    }
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
    this.watch();
    return {
      _meta: {
        [BAYA_META]: {
          agent: this.pane.agent,
          agentName: agentLabel(this.pane.agent),
          title: this.title,
          working: this.working,
          herdr: { pane: this.pane.paneId, status: this.pane.status },
          promptCapabilities: {},
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
    await this.app.prompt(this.pane.paneId, text);
    this.watch();
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  /** Esc, as its TUI stops a turn. */
  cancel(): void {
    void this.app.sendKeys(this.pane.paneId, ["esc"]).catch(() => {});
  }

  setConfigOption(_phone: PhoneLink, _params: Json): Promise<Json> {
    return Promise.reject(
      RpcError.invalidParams("This agent runs in herdr: change its settings in its terminal."),
    );
  }

  setMode(phone: PhoneLink, params: Json): Promise<Json> {
    return this.setConfigOption(phone, params);
  }

  rename(_title: string): void {}

  stop(): void {
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
    return result;
  }

  private watch(): void {
    const path = this.recordPath;
    if (!path || this.attached.size === 0) return;
    unwatchFile(path);
    watchFile(path, { interval: 500 }, () => this.read());
  }

  /** What the agent wrote since: sent to every phone watching. */
  private read(): void {
    const { updates } = this.load();
    if (updates.length <= this.sent) return;
    const fresh = updates.slice(this.sent);
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
