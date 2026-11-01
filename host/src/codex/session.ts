import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { sessionStatePath } from "../session/identity.js";
import { contextUsageSnapshot } from "../context_usage.js";
import { historyFrames } from "../protocol/history.js";
import { thinkingLevelsFromOptions } from "../protocol/thinking.js";
import type {
  ClientMessage, ExtensionUiRequestWire, ServerMessage, SessionHistoryEvent,
  QueuedMessageItem, ThinkingLevel, WireModel,
} from "../protocol/types.js";
import type { PeerChannel } from "../transport/peer_channel.js";
import { CodexClient, object, type CodexServerRequest, type JsonObject } from "./client.js";

type Client = Pick<CodexClient, "start" | "request" | "respond" | "rejectRequest" | "close" | "on">;
type UserMessage = Extract<ClientMessage, { type: "user_message" }>;
interface PendingApproval { request: CodexServerRequest; tool: string; args: JsonObject }
interface SavedSession {
  threadId: string;
  startedAt: number;
  events: SessionHistoryEvent[];
  contextUsage?: { tokens: number | null; context_window: number | null; percent: number | null };
}

export interface CodexSessionOptions {
  cwd: string;
  broadcast: (message: ServerMessage) => void;
  onBusy?: (busy: boolean) => void;
  onModel?: (model: string) => void;
  onClosed?: (error: Error) => void;
  client?: Client;
  statePath?: string;
}

/** Resume the Codex thread and retain the mobile transcript's stable event ids. */
export class CodexSession {
  private readonly client: Client;
  private readonly statePath: string;
  private threadId = "";
  private contextUsage = contextUsageSnapshot(null, null);
  private startedAt = Date.now();
  private events: SessionHistoryEvent[] = [];
  private turnId: string | null = null;
  private userId: string | null = null;
  private busy = false;
  private startingTurn = false;
  private earlyNotifications: Array<[string, JsonObject]> = [];
  private text = "";
  private textItem = "";
  private model = "";
  private thinking: ThinkingLevel | undefined;
  private readonly modelThinkingLevels = new Map<string, ThinkingLevel[]>();
  private sendChain: Promise<void> = Promise.resolve();
  private readonly approvals = new Map<string, PendingApproval>();
  private readonly questions = new Map<string, CodexServerRequest>();
  private readonly questionPrompts = new Map<string, ExtensionUiRequestWire>();
  private readonly queued = new Map<string, QueuedMessageItem>();
  private draining = false;
  private readonly toolItems = new Map<string, { tool: string; args: JsonObject }>();

  constructor(private readonly options: CodexSessionOptions) {
    this.client = options.client ?? new CodexClient(options.cwd);
    this.statePath = options.statePath ?? sessionStatePath(options.cwd, "codex", "");
    this.client.on("notification", (method, params) => this.notification(method, params));
    this.client.on("request", (request) => this.serverRequest(request));
    this.client.on("closed", (error) => options.onClosed?.(error));
  }

  get isBusy(): boolean { return this.busy; }

  async start(): Promise<void> {
    await this.client.start();
    if (existsSync(this.statePath)) {
      try {
        const saved = object(JSON.parse(readFileSync(this.statePath, "utf8")));
        if (typeof saved.threadId === "string" && saved.threadId) {
          const resumed = object(await this.client.request("thread/resume", {
            threadId: saved.threadId, cwd: this.options.cwd,
          }));
          this.threadId = String(object(resumed.thread).id || saved.threadId);
          this.model = typeof resumed.model === "string" ? resumed.model : "";
          this.startedAt = typeof saved.startedAt === "number" ? saved.startedAt : Date.now();
          this.events = Array.isArray(saved.events) ? saved.events as SessionHistoryEvent[] : [];
          if (saved.contextUsage) {
            const usage = object(saved.contextUsage);
            this.contextUsage = contextUsageSnapshot(usage.tokens, usage.context_window);
          }
          const unfinished = new Map<string, true>();
          this.events = this.events.map((event) => {
            if (event.type === "agent_thinking") return { ...event, complete: true };
            if (event.type === "tool_result") unfinished.delete(event.tool_call_id);
            if (event.type !== "tool_request") return event;
            unfinished.set(event.tool_call_id, true);
            return { ...event, args: { ...event.args, approval_required: false } };
          });
          for (const id of unfinished.keys()) {
            this.events.push({ ts: Date.now(), type: "tool_result", tool_call_id: id, error: "Interrupted when Codex stopped." });
          }
        }
      } catch (error) {
        // Never silently replace a stored thread when authentication/network fails.
        throw new Error(`Could not resume this Codex session: ${error instanceof Error ? error.message : "unknown error"}`);
      }
    }
    if (!this.threadId) await this.newThread();
    this.persist();
    if (this.model) this.options.onModel?.(this.model);
  }

  close(): void {
    this.finishThinking();
    this.flushText();
    this.finishInteractions("Interrupted when Codex stopped.");
    this.busy = false;
    this.persist();
    this.client.close();
  }

  async handle(sender: PeerChannel, message: ClientMessage): Promise<void> {
    try {
      switch (message.type) {
        case "ping": sender.send({ type: "pong", in_reply_to: message.id }); return;
        case "session_sync": this.sync(sender, message.id); return;
        case "user_message":
          await this.enqueue(message);
          return;
        case "cancel":
          if (this.turnId) await this.client.request("turn/interrupt", { threadId: this.threadId, turnId: this.turnId });
          sender.send({ type: "cancelled", in_reply_to: message.id, target_id: message.target_id });
          return;
        case "approve_tool": this.approve(message.tool_call_id, message.decision); return;
        case "extension_ui_response": this.answer(message); return;
        case "context_usage_get":
          sender.send({ type: "context_usage", in_reply_to: message.id, source: "codex", ...this.contextUsage });
          return;
        case "list_models": await this.models(sender, message.id); return;
        case "commands_get":
          sender.send({
            type: "commands_list",
            in_reply_to: message.id,
            commands: [],
          });
          return;
        case "model_set": {
          if (this.busy) throw new Error("Wait for the current response before changing models.");
          const supportedThinking = this.modelThinkingLevels.get(message.model_id);
          if (this.thinking && supportedThinking &&
              !supportedThinking.includes(this.thinking)) this.thinking = undefined;
          this.model = message.model_id;
          this.options.onModel?.(this.model);
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        }
        case "thinking_set": {
          const supportedThinking = this.modelThinkingLevels.get(this.model);
          if (supportedThinking &&
              !supportedThinking.includes(message.level)) {
            throw new Error(`This Codex model does not support ${message.level} reasoning.`);
          }
          this.thinking = message.level;
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        }
        case "session_new":
          await this.sendChain;
          if (this.busy) throw new Error("Stop the current response before starting a new conversation.");
          await this.newThread();
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          this.options.broadcast({ type: "session_history", in_reply_to: message.id,
            session_started_at: this.startedAt, events: [], eos: true, truncated: false });
          return;
        case "session_compact":
          if (this.busy) throw new Error("Wait for the current response before compacting.");
          await this.client.request("thread/compact/start", { threadId: this.threadId });
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        case "queued_message_set":
          if (!message.text.trim()) this.queued.delete(message.id);
          else this.queued.set(message.id, { id: message.id, text: message.text, editable: true,
            created_at: this.queued.get(message.id)?.created_at ?? Date.now() });
          this.broadcastQueue();
          this.drainQueue();
          return;
        case "queued_message_clear":
          if (message.target_id) this.queued.delete(message.target_id);
          else this.queued.clear();
          this.broadcastQueue();
          return;
        default: throw new Error("This action is not supported by Codex.");
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : "Codex request failed.";
      if (["model_set", "thinking_set", "session_new", "session_compact"].includes(message.type)) {
        sender.send({ type: "action_error", action: message.type as "model_set" | "thinking_set" | "session_new" | "session_compact",
          in_reply_to: message.id, error: detail });
      } else sender.send({ type: "error", code: "codex_error", in_reply_to: message.id, message: detail });
    }
  }

  /** Used by the local supervisor's scheduled/manual prompt interface. */
  async sendPrompt(text: string): Promise<void> {
    await this.enqueue({ type: "user_message", id: `local_${Date.now()}`, text });
  }

  private enqueue(message: UserMessage): Promise<void> {
    const operation = this.sendChain.then(() => this.prompt(message));
    this.sendChain = operation.catch(() => { /* The caller renders the failure. */ });
    return operation;
  }

  private broadcastQueue(): void {
    this.options.broadcast({ type: "queued_message_state", items: [...this.queued.values()] });
  }

  private drainQueue(): void {
    if (this.busy || this.draining) return;
    const entry = this.queued.values().next().value;
    if (!entry) return;
    this.draining = true;
    this.queued.delete(entry.id);
    this.broadcastQueue();
    void this.enqueue({ type: "user_message", id: entry.id, text: entry.text }).catch((error: unknown) => {
      this.options.broadcast({ type: "error", code: "codex_error", in_reply_to: entry.id,
        message: error instanceof Error ? error.message : "Could not send queued message." });
    }).finally(() => { this.draining = false; this.drainQueue(); });
  }

  private async newThread(): Promise<void> {
    const result = object(await this.client.request("thread/start", {
      cwd: this.options.cwd, ...(this.model ? { model: this.model } : {}), ephemeral: false,
    }));
    const thread = object(result.thread);
    if (typeof thread.id !== "string" || !thread.id) throw new Error("Codex did not return a thread id.");
    this.finishInteractions("The previous conversation ended.");
    this.threadId = thread.id;
    this.contextUsage = contextUsageSnapshot(null, null);
    this.model = typeof result.model === "string" ? result.model : this.model;
    this.startedAt = Date.now();
    this.events = [];
    this.text = "";
    this.userId = null;
    this.queued.clear();
    this.broadcastQueue();
    this.persist();
  }

  private async prompt(message: UserMessage): Promise<void> {
    const input: JsonObject[] = [{ type: "text", text: message.text, text_elements: [] }];
    for (const image of message.images ?? []) {
      input.push({ type: "image", url: `data:${image.mime};base64,${image.data}` });
    }
    if (this.busy) {
      if (!this.turnId) throw new Error("Codex is starting. Please try again in a moment.");
      await this.client.request("turn/steer", { threadId: this.threadId, expectedTurnId: this.turnId, input });
      this.echo(message);
      return;
    }
    this.startingTurn = true;
    this.earlyNotifications = [];
    this.userId = message.id;
    this.text = "";
    this.textItem = "";
    this.setBusy(true);
    try {
      const result = object(await this.client.request("turn/start", {
        threadId: this.threadId, input, clientUserMessageId: message.id,
        ...(this.model ? { model: this.model } : {}),
        ...(this.thinking
          ? { effort: this.thinking === "off" ? "none" : this.thinking }
          : {}),
      }));
      const turn = object(result.turn);
      this.turnId = typeof turn.id === "string" ? turn.id : null;
      this.echo(message);
    } catch (error) {
      this.setBusy(false);
      throw error;
    } finally {
      this.startingTurn = false;
      const notifications = this.earlyNotifications;
      this.earlyNotifications = [];
      for (const [method, params] of notifications) this.notification(method, params);
    }
  }

  private echo(message: UserMessage): void {
    this.events.push({ ts: Date.now(), type: "user_input", id: message.id, text: message.text,
      ...(message.images?.length ? { images: message.images } : {}) });
    this.options.broadcast(message);
    this.persist();
  }

  private notification(method: string, params: JsonObject): void {
    if (params.threadId && params.threadId !== this.threadId) return;
    if (this.startingTurn) { this.earlyNotifications.push([method, params]); return; }
    if (method === "thread/tokenUsage/updated") {
      if (params.threadId !== this.threadId) return;
      const usage = object(params.tokenUsage);
      this.contextUsage = contextUsageSnapshot(object(usage.last).totalTokens, usage.modelContextWindow);
      // Resume does not replay tokenUsage until the next turn; keep the last
      // known snapshot on disk so a reopened thread still shows context.
      this.persist();
      return;
    }
    if (method === "turn/started") {
      const turn = object(params.turn);
      if (typeof turn.id === "string") this.turnId = turn.id;
      this.setBusy(true);
    } else if (method === "item/agentMessage/delta" && typeof params.delta === "string") {
      const itemId = String(params.itemId ?? "");
      const prefix = this.textItem && this.textItem !== itemId && this.text ? "\n\n" : "";
      this.textItem = itemId;
      this.text += prefix + params.delta;
      this.options.broadcast({ type: "agent_chunk", in_reply_to: this.userId ?? "codex", delta: prefix + params.delta });
    } else if (method === "item/started") {
      const item = object(params.item);
      if (item.type === "reasoning") this.thinkingActivity(String(item.id ?? ""), "", false);
      const tool = this.toolForItem(item);
      if (tool) this.toolRequest(String(item.id), tool.tool, tool.args);
    } else if (method === "item/completed") {
      const item = object(params.item);
      const id = String(item.id ?? "");
      if (item.type === "reasoning") {
        // Only the explicit summary is public display content. Do not read
        // encrypted/raw reasoning, or manufacture a summary when absent.
        const summary = Array.isArray(item.summary) ? item.summary
          .map((entry) => typeof entry === "string" ? entry : String(object(entry).text ?? ""))
          .filter(Boolean).join("\n\n") : "";
        this.thinkingActivity(id, summary, true);
      } else if (this.toolItems.has(id)) {
        const failed = item.status === "failed" || item.status === "declined" || item.exitCode !== null && typeof item.exitCode === "number" && item.exitCode !== 0;
        const result = item.aggregatedOutput ?? item.result ?? item.changes ?? item.contentItems ?? item.status;
        this.toolResult(id, failed ? undefined : result, failed ? String(object(item.error).message ?? item.aggregatedOutput ?? "Tool execution failed.") : undefined);
      } else if (item.type === "agentMessage" && typeof item.text === "string" && this.textItem !== id) {
        const delta = (this.text ? "\n\n" : "") + item.text;
        this.text += delta;
        this.textItem = id;
        this.options.broadcast({ type: "agent_chunk", in_reply_to: this.userId ?? "codex", delta });
      } else if (item.type === "contextCompaction") {
        const marker = { type: "compaction" as const, summary: "Codex compacted the conversation context.", tokens_before: 0 };
        this.events.push({ ...marker, ts: Date.now() });
        this.options.broadcast(marker);
      }
    } else if (method === "turn/completed") {
      const turn = object(params.turn);
      const userId = this.userId;
      this.finishThinking();
      this.flushText();
      this.finishInteractions(turn.status === "interrupted" ? "Interrupted by the user." : "The response ended.");
      if (turn.status === "failed" && userId) {
        this.options.broadcast({ type: "error", in_reply_to: userId, code: "codex_error",
          message: String(object(turn.error).message ?? "Codex could not complete this response.") });
      }
      if (userId) this.options.broadcast({ type: "agent_done", in_reply_to: userId });
      this.turnId = null;
      this.userId = null;
      this.text = "";
      this.textItem = "";
      this.setBusy(false);
      this.persist();
      this.drainQueue();
    } else if (method === "error" && params.willRetry !== true) {
      this.options.broadcast({
        type: "error",
        ...(this.userId ? { in_reply_to: this.userId } : {}),
        code: "codex_error",
        message: String(object(params.error).message ?? params.message ?? "Codex reported an error."),
      });
    }
  }

  private toolForItem(item: JsonObject): { tool: string; args: JsonObject } | null {
    switch (item.type) {
      case "commandExecution": return { tool: "bash", args: { command: item.command, cwd: item.cwd } };
      case "fileChange": return { tool: "apply_patch", args: { changes: item.changes } };
      case "mcpToolCall": return { tool: String(item.tool ?? "MCP"), args: object(item.arguments) };
      case "dynamicToolCall": return { tool: String(item.tool ?? "tool"), args: object(item.arguments) };
      case "webSearch": return { tool: "web_search", args: { action: item.action, query: item.query } };
      default: return null;
    }
  }

  private thinkingActivity(id: string, text: string, complete: boolean): void {
    if (!id) return;
    const key = `thinking_${id}`;
    const index = this.events.findIndex((entry) => entry.type === "agent_thinking" && entry.id === key);
    if (index < 0) this.flushText();
    const event = { type: "agent_thinking" as const, id: key,
      in_reply_to: this.userId ?? "codex", text, complete };
    if (index < 0) this.events.push({ ...event, ts: Date.now() });
    else this.events[index] = { ...event, ts: this.events[index]!.ts };
    this.options.broadcast(event);
  }

  private finishThinking(): void {
    for (const event of this.events) {
      if (event.type === "agent_thinking" && !event.complete) {
        event.complete = true;
        const { ts: _ts, ...message } = event;
        this.options.broadcast(message);
      }
    }
  }

  private toolRequest(id: string, tool: string, args: JsonObject): void {
    const previous = this.toolItems.get(id);
    if (!previous) this.flushText();
    const merged = { ...previous?.args, ...args };
    this.toolItems.set(id, { tool, args: merged });
    const event = { type: "tool_request" as const, tool_call_id: id, tool, args: merged };
    const index = this.events.findIndex((entry) => entry.type === "tool_request" && entry.tool_call_id === id);
    if (index >= 0) this.events[index] = { ...event, ts: this.events[index]!.ts };
    else this.events.push({ ...event, ts: Date.now() });
    this.options.broadcast(event);
  }

  private flushText(): void {
    if (!this.text || !this.userId) return;
    this.events.push({ ts: Date.now(), type: "agent_message", in_reply_to: this.historyTextId(), text: this.text });
    this.text = "";
  }

  private historyTextId(): string {
    const hasSegment = this.events.some((entry) => entry.type === "agent_message" && entry.in_reply_to === this.userId);
    return hasSegment ? `${this.userId}:segment:${this.events.length}` : this.userId!;
  }

  private toolResult(id: string, result?: unknown, error?: string): void {
    const event = { type: "tool_result" as const, tool_call_id: id, ...(error ? { error } : { result }) };
    this.events.push({ ...event, ts: Date.now() });
    this.options.broadcast(event);
    this.approvals.delete(id);
    this.toolItems.delete(id);
    this.persist();
  }

  private finishInteractions(reason: string): void {
    // Codex has ended these RPCs. Do not answer dead request ids or replay
    // their UI into a later turn/thread. Also finish interrupted tool rows.
    for (const id of [...this.toolItems.keys()]) this.toolResult(id, undefined, reason);
    this.approvals.clear();
    for (const id of this.questionPrompts.keys()) {
      this.options.broadcast({ type: "extension_ui_request", id,
        method: "notify", message: reason, notify_type: "info" });
    }
    this.questions.clear();
    this.questionPrompts.clear();
  }

  private serverRequest(request: CodexServerRequest): void {
    if (request.params.threadId && request.params.threadId !== this.threadId) {
      this.client.rejectRequest(request.id, "Unknown thread."); return;
    }
    if (request.method === "item/tool/requestUserInput") {
      const id = `codex_question_${request.id}`;
      const questions = Array.isArray(request.params.questions) ? request.params.questions.map(object) : [];
      this.questions.set(id, request);
      const prompt: ExtensionUiRequestWire = { type: "extension_ui_request", id, method: "input", title: "Codex needs your input",
        ask: { flow_id: id, tool_call_id: null, source: "tool", title: "Codex needs your input",
          questions: questions.map((question) => ({
            id: String(question.id), label: String(question.header ?? "Question"), prompt: String(question.question ?? ""),
            type: "single", required: true,
            options: [...(Array.isArray(question.options) ? question.options.map((value) => {
              const option = object(value);
              return { value: String(option.label), label: String(option.label), description: String(option.description ?? "") };
            }) : []), ...(question.isOther || !Array.isArray(question.options) || question.options.length === 0
              ? [{ value: "__other__", label: "Your answer", freeform: true }] : [])],
          })),
        } };
      this.questionPrompts.set(id, prompt);
      this.options.broadcast(prompt);
    } else if (["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].includes(request.method)) {
      const id = String(request.params.itemId ?? `codex_approval_${request.id}`);
      const existing = this.toolItems.get(id);
      const tool = existing?.tool ?? (request.method.includes("fileChange") ? "apply_patch" : request.method.includes("permissions") ? "permissions" : "bash");
      const args = { ...existing?.args, command: request.params.command, cwd: request.params.cwd,
        reason: request.params.reason, permissions: request.params.permissions, approval_required: true };
      this.approvals.set(id, { request, tool, args });
      this.toolRequest(id, tool, args);
    } else {
      this.client.rejectRequest(request.id, `Unsupported mobile request: ${request.method}`);
    }
  }

  private approve(id: string, decision: "allow" | "deny"): void {
    const pending = this.approvals.get(id);
    if (!pending) throw new Error("This request has already been answered.");
    const isPermissions = pending.request.method.includes("permissions");
    this.client.respond(pending.request.id, isPermissions
      ? { permissions: decision === "allow" ? object(pending.request.params.permissions) : {}, scope: "turn" }
      : { decision: decision === "allow" ? "accept" : "decline" });
    this.approvals.delete(id);
    this.toolRequest(id, pending.tool, { ...pending.args, approval_required: false, approval_decision: decision });
    if (isPermissions || decision === "deny") this.toolResult(id, decision === "allow" ? "Allowed for this turn." : undefined,
      decision === "deny" ? "Denied by the user." : undefined);
  }

  private answer(message: Extract<ClientMessage, { type: "extension_ui_response" }>): void {
    const request = this.questions.get(message.id);
    if (!request) return;
    const answers: Record<string, { answers: string[] }> = {};
    if (message.ask?.kind === "answer") {
      for (const [id, answer] of Object.entries(message.ask.answers)) {
        answers[id] = { answers: [...(answer.values ?? []).filter((value) => value !== "__other__"),
          ...(answer.customText ? [answer.customText] : []), ...(answer.note ? [answer.note] : [])] };
      }
    }
    this.client.respond(request.id, { answers });
    this.questions.delete(message.id);
    this.questionPrompts.delete(message.id);
    // Every connected phone must close the same answered question.
    this.options.broadcast({ type: "extension_ui_request", id: message.id,
      method: "notify", message: "Answered", notify_type: "info" });
  }

  private async models(sender: PeerChannel, id: string): Promise<void> {
    const response = object(await this.client.request("model/list", { limit: 100 }));
    const models: WireModel[] = (Array.isArray(response.data) ? response.data : []).map(object)
      .filter((entry) => entry.hidden !== true).map((entry) => {
        const thinkingLevels = thinkingLevelsFromOptions(
          Array.isArray(entry.supportedReasoningEfforts)
            ? entry.supportedReasoningEfforts
            : [],
        );
        const id = String(entry.model ?? entry.id);
        this.modelThinkingLevels.set(id, thinkingLevels);
        return {
          id, name: String(entry.displayName ?? entry.model ?? entry.id), provider: "codex",
          reasoning: thinkingLevels.some((level) => level !== "off"),
          thinking_levels: thinkingLevels,
          context_window: 0, vision: Array.isArray(entry.inputModalities) && entry.inputModalities.includes("image"),
        };
      });
    const current = models.find((entry) => entry.id === this.model);
    sender.send({ type: "models_list", in_reply_to: id, models, ...(current ? { current } : {}) });
  }

  private sync(sender: PeerChannel, id: string): void {
    // A live cursor is separate from completed history. Receivers replace
    // their streaming buffer with it, then append subsequent delta frames.
    const frames = historyFrames({ in_reply_to: id,
      session_started_at: this.startedAt, events: [...this.events], truncated: false,
      streaming: this.busy && this.userId ? { in_reply_to: this.userId, text: this.text } : null });
    for (const frame of frames) sender.send(frame);
    // Reconnects must restore outstanding decisions, not silently allow them.
    for (const [tool_call_id, approval] of this.approvals) {
      sender.send({ type: "tool_request", tool_call_id, tool: approval.tool, args: approval.args });
    }
    for (const prompt of this.questionPrompts.values()) sender.send(prompt);
    sender.send({ type: "queued_message_state", items: [...this.queued.values()] });
  }

  private setBusy(value: boolean): void { this.busy = value; this.options.onBusy?.(value); }

  private persist(): void {
    if (!this.threadId) return;
    const saved: SavedSession = {
      threadId: this.threadId,
      startedAt: this.startedAt,
      events: this.events,
      contextUsage: this.contextUsage,
    };
    mkdirSync(dirname(this.statePath), { recursive: true, mode: 0o700 });
    const temp = this.statePath + ".tmp";
    writeFileSync(temp, JSON.stringify(saved), { mode: 0o600 });
    renameSync(temp, this.statePath);
  }
}
