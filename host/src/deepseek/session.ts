import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { sessionStatePath } from "../session/identity.js";
import { contextUsageSnapshot } from "../context_usage.js";
import { historyFrames } from "../protocol/history.js";
import { thinkingLevelsFromOptions } from "../protocol/thinking.js";
import type {
  ClientMessage,
  QueuedMessageItem,
  ServerMessage,
  SessionHistoryEvent,
  WireModel,
} from "../protocol/types.js";
import type { PeerChannel } from "../transport/peer_channel.js";
import {
  DeepSeekClient,
  object,
  type DeepSeekServerRequest,
  type JsonObject,
} from "./client.js";
import { syncDeepSeekWorkspace } from "./workspace_sync.js";

type Client = Pick<
  DeepSeekClient,
  "start" | "request" | "notify" | "respond" | "rejectRequest" | "close" | "on"
>;
type UserMessage = Extract<ClientMessage, { type: "user_message" }>;

interface SavedSession {
  sessionId: string;
  startedAt: number;
  events: SessionHistoryEvent[];
  contextUsage?: {
    tokens: number | null;
    context_window: number | null;
    percent: number | null;
  };
}

interface AcpConfigOption {
  id: string;
  name: string;
  type: string;
  category?: string;
  currentValue: unknown;
  options?: unknown[];
}

interface ModelChoice {
  value: string;
  provider: string;
  model: string;
  name: string;
  description?: string;
}

interface PendingPermission {
  request: DeepSeekServerRequest;
  allowOptionId: string;
  rejectOptionId: string;
}

export interface DeepSeekSessionOptions {
  cwd: string;
  broadcast: (message: ServerMessage) => void;
  onBusy?: (busy: boolean) => void;
  onModel?: (model: string) => void;
  onClosed?: (error: Error) => void;
  client?: Client;
  statePath?: string;
  syncWorkspace?: (cwd: string, sessionId: string) => Promise<unknown>;
}

/** Adapt one persistent DeepSeek Harness ACP session to the mobile wire. */
export class DeepSeekSession {
  private readonly client: Client;
  private readonly statePath: string;
  private sessionId = "";
  private configOptions: AcpConfigOption[] = [];
  private modelChoices: ModelChoice[] = [];
  private contextUsage = contextUsageSnapshot(null, null);
  private startedAt = Date.now();
  private events: SessionHistoryEvent[] = [];
  private userId: string | null = null;
  private busy = false;
  private text = "";
  private textItem = "";
  private supportsImages = false;
  private sendChain: Promise<void> = Promise.resolve();
  private readonly permissions = new Map<string, PendingPermission>();
  private readonly toolItems = new Map<string, { tool: string; args: JsonObject }>();
  private readonly queued = new Map<string, QueuedMessageItem>();
  private draining = false;

  constructor(private readonly options: DeepSeekSessionOptions) {
    this.client = options.client ?? new DeepSeekClient(options.cwd);
    this.statePath = options.statePath ?? sessionStatePath(options.cwd, "deepseek", "");
    this.client.on("notification", (method, params) => this.notification(method, params));
    this.client.on("request", (request) => this.serverRequest(request));
    this.client.on("closed", (error) => options.onClosed?.(error));
  }

  get isBusy(): boolean {
    return this.busy;
  }

  async start(): Promise<void> {
    const started = await this.client.start();
    this.supportsImages = started.supportsImages;
    if (existsSync(this.statePath)) {
      try {
        const saved = object(JSON.parse(readFileSync(this.statePath, "utf8")));
        if (typeof saved.sessionId === "string" && saved.sessionId) {
          const resumed = object(await this.client.request(
            "session/resume",
            { sessionId: saved.sessionId, cwd: this.options.cwd, mcpServers: [] },
            120_000,
          ));
          this.sessionId = saved.sessionId;
          this.startedAt = typeof saved.startedAt === "number"
            ? saved.startedAt
            : Date.now();
          this.events = Array.isArray(saved.events)
            ? saved.events as SessionHistoryEvent[]
            : [];
          if (saved.contextUsage) {
            const usage = object(saved.contextUsage);
            this.contextUsage = contextUsageSnapshot(
              usage.tokens,
              usage.context_window,
            );
          }
          this.repairInterruptedHistory();
          this.updateConfigOptions(resumed.configOptions);
        }
      } catch (error) {
        throw new Error(
          `Could not resume this DeepSeek session: ${
            error instanceof Error ? error.message : "unknown error"
          }`,
        );
      }
    }
    if (!this.sessionId) await this.newSession();
    else await this.syncDesktopWorkspace();
    this.persist();
  }

  close(): void {
    this.finishThinking();
    this.flushText();
    this.finishInteractions("Interrupted when DeepSeek Harness stopped.");
    this.cancelPendingPermissions();
    this.setBusy(false);
    this.persist();
    this.client.close();
  }

  async handle(sender: PeerChannel, message: ClientMessage): Promise<void> {
    try {
      switch (message.type) {
        case "ping":
          sender.send({ type: "pong", in_reply_to: message.id });
          return;
        case "session_sync":
          this.sync(sender, message.id);
          return;
        case "user_message":
          await this.enqueue(message);
          return;
        case "cancel":
          this.cancelPendingPermissions();
          if (this.busy) {
            this.client.notify("session/cancel", { sessionId: this.sessionId });
          }
          sender.send({
            type: "cancelled",
            in_reply_to: message.id,
            target_id: message.target_id,
          });
          return;
        case "approve_tool":
          this.approve(message.tool_call_id, message.decision);
          return;
        case "context_usage_get":
          sender.send({
            type: "context_usage",
            in_reply_to: message.id,
            source: "deepseek",
            ...this.contextUsage,
          });
          return;
        case "list_models":
          this.models(sender, message.id);
          return;
        case "commands_get":
          sender.send({
            type: "commands_list",
            in_reply_to: message.id,
            commands: [],
          });
          return;
        case "model_set":
          await this.setModel(message.model_id, message.provider);
          sender.send({
            type: "action_ok",
            action: message.type,
            in_reply_to: message.id,
          });
          return;
        case "thinking_set":
          await this.setThinking(message.level);
          sender.send({
            type: "action_ok",
            action: message.type,
            in_reply_to: message.id,
          });
          return;
        case "session_new":
          await this.sendChain;
          if (this.busy) {
            throw new Error("Stop the current response before starting a new conversation.");
          }
          await this.newSession();
          sender.send({
            type: "action_ok",
            action: message.type,
            in_reply_to: message.id,
          });
          this.options.broadcast({
            type: "session_history",
            in_reply_to: message.id,
            session_started_at: this.startedAt,
            events: [],
            eos: true,
            truncated: false,
          });
          return;
        case "session_compact":
          throw new Error(
            "DeepSeek Harness does not expose context compaction through ACP.",
          );
        case "queued_message_set":
          if (!message.text.trim()) {
            this.queued.delete(message.id);
          } else {
            this.queued.set(message.id, {
              id: message.id,
              text: message.text,
              editable: true,
              created_at: this.queued.get(message.id)?.created_at ?? Date.now(),
            });
          }
          this.broadcastQueue();
          this.drainQueue();
          return;
        case "queued_message_clear":
          if (message.target_id) this.queued.delete(message.target_id);
          else this.queued.clear();
          this.broadcastQueue();
          return;
        case "extension_ui_response":
          throw new Error(
            "DeepSeek Harness does not expose interactive questions through ACP.",
          );
        default:
          throw new Error("This action is not supported by DeepSeek Harness.");
      }
    } catch (error) {
      const detail = error instanceof Error
        ? error.message
        : "DeepSeek Harness request failed.";
      if (
        message.type === "model_set"
        || message.type === "thinking_set"
        || message.type === "session_new"
        || message.type === "session_compact"
      ) {
        sender.send({
          type: "action_error",
          action: message.type,
          in_reply_to: message.id,
          error: detail,
        });
      } else {
        sender.send({
          type: "error",
          code: "deepseek_error",
          in_reply_to: message.id,
          message: detail,
        });
      }
    }
  }

  /** Local supervisor/manual prompt entry point. */
  async sendPrompt(text: string): Promise<void> {
    await this.enqueue({
      type: "user_message",
      id: `local_${Date.now()}`,
      text,
    });
  }

  private enqueue(message: UserMessage): Promise<void> {
    const operation = this.sendChain.then(() => this.prompt(message));
    this.sendChain = operation.catch(() => {
      // The prompt path broadcasts its own error.
    });
    return operation;
  }

  private async newSession(): Promise<void> {
    const previous = this.sessionId;
    if (previous) {
      try {
        await this.client.request(
          "session/close",
          { sessionId: previous },
          30_000,
        );
      } catch {
        // The new session can still be created if persistence refuses close.
      }
    }
    const created = object(await this.client.request(
      "session/new",
      { cwd: this.options.cwd, mcpServers: [] },
      120_000,
    ));
    if (typeof created.sessionId !== "string" || !created.sessionId) {
      throw new Error("DeepSeek Harness did not return a session id.");
    }
    this.finishInteractions("The previous conversation ended.");
    this.sessionId = created.sessionId;
    this.startedAt = Date.now();
    this.events = [];
    this.contextUsage = contextUsageSnapshot(null, null);
    this.userId = null;
    this.text = "";
    this.textItem = "";
    this.queued.clear();
    this.updateConfigOptions(created.configOptions);
    this.broadcastQueue();
    this.persist();
    await this.syncDesktopWorkspace();
  }

  private async prompt(message: UserMessage): Promise<void> {
    if (this.busy) {
      throw new Error("DeepSeek Harness is still working on the previous message.");
    }
    if ((message.images?.length ?? 0) > 0 && !this.supportsImages) {
      throw new Error("The selected DeepSeek route does not accept images.");
    }
    const prompt: JsonObject[] = [{ type: "text", text: message.text }];
    for (const image of message.images ?? []) {
      prompt.push({
        type: "image",
        data: image.data,
        mimeType: image.mime,
      });
    }
    this.userId = message.id;
    this.text = "";
    this.textItem = "";
    this.echo(message);
    this.setBusy(true);
    try {
      const response = object(await this.client.request(
        "session/prompt",
        { sessionId: this.sessionId, prompt },
        0,
      ));
      if (response.stopReason === "refusal") {
        this.options.broadcast({
          type: "error",
          in_reply_to: message.id,
          code: "deepseek_error",
          message: "DeepSeek refused this request.",
        });
      } else if (response.stopReason === "max_tokens") {
        this.options.broadcast({
          type: "error",
          in_reply_to: message.id,
          code: "deepseek_error",
          message: "DeepSeek reached the output token limit.",
        });
      }
    } catch (error) {
      this.options.broadcast({
        type: "error",
        in_reply_to: message.id,
        code: "deepseek_error",
        message: error instanceof Error
          ? error.message
          : "DeepSeek Harness could not complete this response.",
      });
      throw error;
    } finally {
      this.finishThinking();
      this.flushText();
      this.finishInteractions("DeepSeek stopped before the tool call completed.");
      this.cancelPendingPermissions();
      if (this.userId) {
        this.options.broadcast({
          type: "agent_done",
          in_reply_to: this.userId,
        });
      }
      this.userId = null;
      this.text = "";
      this.textItem = "";
      this.setBusy(false);
      this.persist();
      await this.syncDesktopWorkspace();
      this.drainQueue();
    }
  }

  private echo(message: UserMessage): void {
    this.events.push({
      ts: Date.now(),
      type: "user_input",
      id: message.id,
      text: message.text,
      ...(message.images?.length ? { images: message.images } : {}),
    });
    this.options.broadcast(message);
    this.persist();
  }

  private notification(method: string, params: JsonObject): void {
    if (method !== "session/update") return;
    if (params.sessionId !== this.sessionId) return;
    const update = object(params.update);
    const kind = update.sessionUpdate;
    if (kind === "agent_message_chunk") {
      this.agentMessageChunk(update);
    } else if (kind === "agent_thought_chunk") {
      this.thoughtChunk(update);
    } else if (kind === "tool_call") {
      this.toolCall(update);
    } else if (kind === "tool_call_update") {
      this.toolCallUpdate(update);
    } else if (kind === "usage_update") {
      this.contextUsage = contextUsageSnapshot(update.used, update.size);
      this.persist();
    } else if (kind === "config_option_update") {
      this.updateConfigOptions(update.configOptions);
      this.persist();
    } else if (kind === "notice" && update.severity === "error") {
      this.options.broadcast({
        type: "error",
        ...(this.userId ? { in_reply_to: this.userId } : {}),
        code: "deepseek_error",
        message: String(update.message ?? "DeepSeek Harness reported an error."),
      });
    }
  }

  private agentMessageChunk(update: JsonObject): void {
    const content = object(update.content);
    if (content.type !== "text" || typeof content.text !== "string") return;
    this.finishThinking();
    const itemId = typeof update.messageId === "string" ? update.messageId : "message";
    const prefix = this.textItem && this.textItem !== itemId && this.text ? "\n\n" : "";
    this.textItem = itemId;
    this.text += prefix + content.text;
    this.options.broadcast({
      type: "agent_chunk",
      in_reply_to: this.userId ?? "deepseek",
      delta: prefix + content.text,
    });
  }

  private thoughtChunk(update: JsonObject): void {
    const content = object(update.content);
    if (content.type !== "text" || typeof content.text !== "string") return;
    const messageId = typeof update.messageId === "string"
      ? update.messageId
      : "thought";
    const key = `thinking_${messageId}`;
    const index = this.events.findIndex(
      (entry) => entry.type === "agent_thinking" && entry.id === key,
    );
    if (index < 0) this.flushText();
    const previous = index >= 0 ? this.events[index] : undefined;
    const text = previous?.type === "agent_thinking"
      ? previous.text + content.text
      : content.text;
    const event = {
      type: "agent_thinking" as const,
      id: key,
      in_reply_to: this.userId ?? "deepseek",
      text,
      complete: false,
    };
    if (index < 0) this.events.push({ ...event, ts: Date.now() });
    else this.events[index] = { ...event, ts: this.events[index]!.ts };
    this.options.broadcast(event);
  }

  private toolCall(update: JsonObject): void {
    const id = String(update.toolCallId ?? "");
    if (!id) return;
    const title = String(update.title ?? update.name ?? "tool");
    const name = String(update.name ?? update.title ?? "tool");
    this.toolRequest(id, name, {
      ...rawInputArgs(update.rawInput),
      title,
      kind: update.kind,
    });
  }

  private toolCallUpdate(update: JsonObject): void {
    const id = String(update.toolCallId ?? "");
    if (!id) return;
    const previous = this.toolItems.get(id);
    const title = typeof update.title === "string"
      ? update.title
      : String(previous?.args.title ?? "");
    const tool = String(update.name ?? previous?.tool ?? title ?? "tool");
    const args: JsonObject = {
      ...previous?.args,
      ...rawInputArgs(update.rawInput),
      ...(title ? { title } : {}),
      ...(update.kind !== undefined ? { kind: update.kind } : {}),
    };
    this.toolRequest(id, tool, args);
    const status = String(update.status ?? "");
    if (status === "completed" || status === "failed") {
      const result = toolResultValue(update);
      this.toolResult(
        id,
        status === "failed" ? undefined : result,
        status === "failed"
          ? toolFailureValue(update, result)
          : undefined,
      );
    }
  }

  private toolRequest(id: string, tool: string, args: JsonObject): void {
    const previous = this.toolItems.get(id);
    if (!previous) this.flushText();
    const merged = { ...previous?.args, ...args };
    this.toolItems.set(id, { tool, args: merged });
    const event = {
      type: "tool_request" as const,
      tool_call_id: id,
      tool,
      args: merged,
    };
    const index = this.events.findIndex(
      (entry) => entry.type === "tool_request" && entry.tool_call_id === id,
    );
    if (index >= 0) {
      this.events[index] = {
        ...event,
        ts: this.events[index]!.ts,
      };
    } else {
      this.events.push({ ...event, ts: Date.now() });
    }
    this.options.broadcast(event);
    this.persist();
  }

  private toolResult(id: string, result?: unknown, error?: string): void {
    const event = {
      type: "tool_result" as const,
      tool_call_id: id,
      ...(error ? { error } : { result }),
    };
    this.events.push({ ...event, ts: Date.now() });
    this.options.broadcast(event);
    this.permissions.delete(id);
    this.toolItems.delete(id);
    this.persist();
  }

  private thoughtOrTextOpen(): boolean {
    return this.text.length > 0
      || this.events.some(
        (entry) => entry.type === "agent_thinking" && !entry.complete,
      );
  }

  private finishThinking(): void {
    if (!this.thoughtOrTextOpen()) return;
    for (const event of this.events) {
      if (event.type === "agent_thinking" && !event.complete) {
        event.complete = true;
        const { ts: _ts, ...message } = event;
        this.options.broadcast(message);
      }
    }
  }

  private flushText(): void {
    if (!this.text || !this.userId) return;
    this.events.push({
      ts: Date.now(),
      type: "agent_message",
      in_reply_to: this.historyTextId(),
      text: this.text,
    });
    this.text = "";
  }

  private historyTextId(): string {
    const hasSegment = this.events.some(
      (entry) =>
        entry.type === "agent_message"
        && entry.in_reply_to === this.userId,
    );
    return hasSegment
      ? `${this.userId}:segment:${this.events.length}`
      : this.userId!;
  }

  private serverRequest(request: DeepSeekServerRequest): void {
    if (
      request.params.sessionId !== undefined
      && request.params.sessionId !== this.sessionId
    ) {
      this.client.rejectRequest(request.id, "Unknown session.");
      return;
    }
    if (request.method !== "session/request_permission") {
      this.client.rejectRequest(
        request.id,
        `Unsupported ACP client request: ${request.method}`,
      );
      return;
    }
    const toolCall = object(request.params.toolCall);
    const id = String(toolCall.toolCallId ?? "");
    const options = Array.isArray(request.params.options)
      ? request.params.options.map(object)
      : [];
    const allow = options.find((option) => option.kind === "allow_once");
    const reject = options.find((option) => option.kind === "reject_once");
    if (!id || typeof allow?.optionId !== "string" || typeof reject?.optionId !== "string") {
      this.client.rejectRequest(
        request.id,
        "DeepSeek requested an unsupported permission choice.",
      );
      return;
    }
    const existing = this.toolItems.get(id);
    const tool = String(toolCall.name ?? existing?.tool ?? toolCall.title ?? "tool");
    this.toolRequest(id, tool, {
      ...existing?.args,
      ...rawInputArgs(toolCall.rawInput),
      ...(toolCall.title !== undefined ? { title: toolCall.title } : {}),
      approval_required: true,
    });
    this.permissions.set(id, {
      request,
      allowOptionId: allow.optionId,
      rejectOptionId: reject.optionId,
    });
  }

  private approve(id: string, decision: "allow" | "deny"): void {
    const pending = this.permissions.get(id);
    if (!pending) throw new Error("This request has already been answered.");
    this.client.respond(pending.request.id, {
      outcome: {
        outcome: "selected",
        optionId: decision === "allow"
          ? pending.allowOptionId
          : pending.rejectOptionId,
      },
    });
    this.permissions.delete(id);
    const existing = this.toolItems.get(id);
    if (existing) {
      this.toolRequest(id, existing.tool, {
        ...existing.args,
        approval_required: false,
        approval_decision: decision,
      });
    }
  }

  private cancelPendingPermissions(): void {
    for (const pending of this.permissions.values()) {
      try {
        this.client.respond(pending.request.id, {
          outcome: { outcome: "cancelled" },
        });
      } catch {
        // The connection may already be gone.
      }
    }
    this.permissions.clear();
  }

  private updateConfigOptions(raw: unknown): void {
    this.configOptions = Array.isArray(raw)
      ? raw.map((entry) => {
          const option = object(entry);
          return {
            id: String(option.id ?? ""),
            name: String(option.name ?? option.id ?? ""),
            type: String(option.type ?? ""),
            currentValue: option.currentValue,
            options: Array.isArray(option.options) ? option.options : [],
            ...(typeof option.category === "string" ? { category: option.category } : {}),
          };
        }).filter((option) => option.id)
      : [];
    this.modelChoices = [];
    const modelOption = this.configOptions.find(
      (option) => option.category === "model" || option.id === "model",
    );
    for (const entry of modelOption?.options ?? []) {
      const group = object(entry);
      if (Array.isArray(group.options)) {
        const provider = String(group.group ?? group.name ?? "");
        for (const child of group.options) {
          const choice = modelChoice(child, provider);
          if (choice) this.modelChoices.push(choice);
        }
      } else {
        const choice = modelChoice(entry, "");
        if (choice) this.modelChoices.push(choice);
      }
    }
    const current = this.currentModel();
    if (current) this.options.onModel?.(current.model);
  }

  private currentModel(): ModelChoice | undefined {
    const option = this.configOptions.find(
      (entry) => entry.category === "model" || entry.id === "model",
    );
    if (typeof option?.currentValue !== "string") return undefined;
    const parsed = parseModelValue(option.currentValue);
    return this.modelChoices.find(
      (choice) =>
        choice.provider === parsed.provider
        && choice.model === parsed.model,
    ) ?? this.modelChoices.find((choice) => choice.value === option.currentValue);
  }

  private async setModel(modelId: string, provider: string): Promise<void> {
    if (this.busy) {
      throw new Error("Wait for the current response before changing models.");
    }
    const option = this.configOptions.find(
      (entry) => entry.category === "model" || entry.id === "model",
    );
    if (!option) throw new Error("DeepSeek did not advertise a model selector.");
    const choice = this.modelChoices.find(
      (entry) =>
        entry.model === modelId
        && (!provider || entry.provider === provider),
    );
    if (!choice) throw new Error("Choose a model from the DeepSeek catalog.");
    const changed = object(await this.client.request(
      "session/set_config_option",
      {
        sessionId: this.sessionId,
        configId: option.id,
        value: choice.value,
      },
    ));
    this.updateConfigOptions(changed.configOptions);
    this.persist();
  }

  private async setThinking(
    level: Extract<ClientMessage, { type: "thinking_set" }>["level"],
  ): Promise<void> {
    if (this.busy) {
      throw new Error("Wait for the current response before changing reasoning effort.");
    }
    const option = this.configOptions.find(
      (entry) =>
        entry.category === "thought_level"
        || entry.id === "reasoning_effort",
    );
    if (!option) {
      if (level === "off") return;
      throw new Error("The selected model does not advertise reasoning effort.");
    }
    const value = findThinkingValue(option, level);
    if (value === undefined) {
      throw new Error(`This DeepSeek model does not support ${level} reasoning.`);
    }
    const changed = object(await this.client.request(
      "session/set_config_option",
      { sessionId: this.sessionId, configId: option.id, value },
    ));
    this.updateConfigOptions(changed.configOptions);
    this.persist();
  }

  private models(sender: PeerChannel, id: string): void {
    const effortOption = this.configOptions.find(
      (entry) =>
        entry.category === "thought_level"
        || entry.id === "reasoning_effort",
    );
    const thinkingLevels = thinkingLevelsFromOptions(effortOption?.options ?? []);
    const reasoning = thinkingLevels.some((level) => level !== "off");
    const models: WireModel[] = this.modelChoices.map((choice) => ({
      id: choice.model,
      name: choice.name,
      provider: choice.provider || "deepseek",
      reasoning,
      thinking_levels: thinkingLevels,
      context_window: 0,
      vision: this.supportsImages,
    }));
    const current = this.currentModel();
    const selected = current
      ? models.find(
          (entry) =>
            entry.id === current.model
            && entry.provider === (current.provider || "deepseek"),
        )
      : undefined;
    sender.send({
      type: "models_list",
      in_reply_to: id,
      models,
      ...(selected ? { current: selected } : {}),
    });
  }

  private sync(sender: PeerChannel, id: string): void {
    const frames = historyFrames({
      in_reply_to: id,
      session_started_at: this.startedAt,
      events: [...this.events],
      streaming: this.busy && this.userId
        ? { in_reply_to: this.userId, text: this.text }
        : null,
      truncated: false,
    });
    for (const frame of frames) sender.send(frame);
    for (const [toolCallId] of this.permissions) {
      const item = this.toolItems.get(toolCallId);
      if (item) {
        sender.send({
          type: "tool_request",
          tool_call_id: toolCallId,
          tool: item.tool,
          args: item.args,
        });
      }
    }
    sender.send({
      type: "queued_message_state",
      items: [...this.queued.values()],
    });
  }

  private finishInteractions(reason: string): void {
    for (const id of [...this.toolItems.keys()]) {
      this.toolResult(id, undefined, reason);
    }
  }

  private repairInterruptedHistory(): void {
    const unfinished = new Map<string, true>();
    this.events = this.events.map((event) => {
      if (event.type === "agent_thinking") {
        return { ...event, complete: true };
      }
      if (event.type === "tool_result") unfinished.delete(event.tool_call_id);
      if (event.type !== "tool_request") return event;
      unfinished.set(event.tool_call_id, true);
      return {
        ...event,
        args: { ...event.args, approval_required: false },
      };
    });
    for (const id of unfinished.keys()) {
      this.events.push({
        ts: Date.now(),
        type: "tool_result",
        tool_call_id: id,
        error: "Interrupted when DeepSeek Harness stopped.",
      });
    }
  }

  private broadcastQueue(): void {
    this.options.broadcast({
      type: "queued_message_state",
      items: [...this.queued.values()],
    });
  }

  private drainQueue(): void {
    if (this.busy || this.draining) return;
    const entry = this.queued.values().next().value;
    if (!entry) return;
    this.draining = true;
    this.queued.delete(entry.id);
    this.broadcastQueue();
    void this.enqueue({
      type: "user_message",
      id: entry.id,
      text: entry.text,
    }).catch((error: unknown) => {
      this.options.broadcast({
        type: "error",
        code: "deepseek_error",
        in_reply_to: entry.id,
        message: error instanceof Error
          ? error.message
          : "Could not send queued message.",
      });
    }).finally(() => {
      this.draining = false;
      this.drainQueue();
    });
  }

  private setBusy(value: boolean): void {
    this.busy = value;
    this.options.onBusy?.(value);
  }

  private async syncDesktopWorkspace(): Promise<void> {
    if (!this.sessionId) return;
    try {
      await (this.options.syncWorkspace ?? syncDeepSeekWorkspace)(
        this.options.cwd,
        this.sessionId,
      );
    } catch (error) {
      process.stderr.write(
        `[baya] DeepSeek workspace sync skipped: ${
          error instanceof Error ? error.message : String(error)
        }\n`,
      );
    }
  }

  private persist(): void {
    if (!this.sessionId) return;
    const saved: SavedSession = {
      sessionId: this.sessionId,
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

function modelChoice(raw: unknown, fallbackProvider: string): ModelChoice | null {
  const entry = object(raw);
  if (typeof entry.value !== "string") return null;
  const parsed = parseModelValue(entry.value);
  return {
    value: entry.value,
    provider: parsed.provider || fallbackProvider,
    model: parsed.model || entry.value,
    name: String(entry.name ?? parsed.model ?? entry.value),
    ...(typeof entry.description === "string"
      ? { description: entry.description }
      : {}),
  };
}

function parseModelValue(value: string): { provider: string; model: string } {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (
      Array.isArray(parsed)
      && typeof parsed[0] === "string"
      && typeof parsed[1] === "string"
    ) {
      return { provider: parsed[0], model: parsed[1] };
    }
  } catch {
    // ACP model values are opaque; providers may use a non-JSON convention.
  }
  return { provider: "", model: value };
}

function findThinkingValue(
  option: AcpConfigOption,
  level: Extract<ClientMessage, { type: "thinking_set" }>["level"],
): string | undefined {
  const options = (option.options ?? []).map(object);
  const aliases: Record<string, string[]> = {
    off: ["off", "none", "disabled", ""],
    minimal: ["minimal", "min"],
    low: ["low"],
    medium: ["medium", "med"],
    high: ["high"],
    xhigh: ["xhigh", "x-high", "extra high"],
    max: ["max", "maximum"],
    ultra: ["ultra"],
  };
  const wanted = aliases[level] ?? [level];
  for (const alias of wanted) {
    const match = options.find((entry) =>
      String(entry.value ?? "").toLowerCase() === alias
      || String(entry.name ?? "").toLowerCase() === alias
    );
    if (typeof match?.value === "string") return match.value;
  }
  return undefined;
}

function toolResultValue(update: JsonObject): unknown {
  if (update.rawOutput !== undefined) return update.rawOutput;
  const content = Array.isArray(update.content)
    ? update.content.map(toolContentValue).filter((value) => value !== undefined)
    : [];
  if (content.length === 0) return update.status;
  return content.length === 1 ? content[0] : content;
}

function toolFailureValue(update: JsonObject, result: unknown): string {
  if (typeof update.rawOutput === "string" && update.rawOutput) {
    return update.rawOutput;
  }
  if (typeof result === "string" && result) return result;
  return "DeepSeek tool execution failed.";
}

function toolContentValue(raw: unknown): unknown {
  const entry = object(raw);
  if (entry.type === "content") {
    const content = object(entry.content);
    return content.text ?? entry.content;
  }
  return entry;
}

function rawInputArgs(value: unknown): JsonObject {
  if (value === undefined) return {};
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    return value as JsonObject;
  }
  return { input: value };
}
