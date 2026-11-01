import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { spawnPlan } from "../process/spawn.js";
import { historyFrames } from "../protocol/history.js";
import { thinkingLevelsFromMap } from "../protocol/thinking.js";
import type {
  ClientMessage,
  ExtensionUiRequestWire,
  ServerMessage,
  SessionHistoryEvent,
  Usage,
  WireImage,
  WireModel,
} from "../protocol/types.js";
import type { PeerChannel } from "../transport/peer_channel.js";
import type { AgentAdapter, AdapterOptions } from "./types.js";

type JsonObject = Record<string, unknown>;
type RpcId = string;

interface RpcPending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

function record(value: unknown): JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function usage(value: unknown): { input_tokens: number; output_tokens: number } | undefined {
  const raw = record(value);
  if (Object.keys(raw).length === 0) return undefined;
  return {
    input_tokens: numberValue(raw["input"]),
    output_tokens: numberValue(raw["output"]),
  };
}

function readableToolResult(value: unknown): unknown {
  const result = record(value);
  const content = contentText(result["content"]);
  if (content) return content;
  if (result["details"] !== undefined) return result["details"];
  if (result["structuredContent"] !== undefined) return result["structuredContent"];
  return value;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  return array(content)
    .map((block) => {
      const item = record(block);
      if (item["type"] === "text") return stringValue(item["text"]);
      if (item["type"] === "image") return "[Image]";
      return "";
    })
    .filter(Boolean)
    .join("");
}

function imageWire(content: unknown): WireImage[] {
  return array(content).flatMap((block): WireImage[] => {
    const item = record(block);
    if (item["type"] !== "image") return [];
    return [{
      data: stringValue(item["data"]),
      mime: stringValue(item["mimeType"]) || "image/jpeg",
    }];
  });
}

/**
 * Small JSONL client for Pi's documented RPC mode. It intentionally has no
 * dependency on Pi's SDK and never loads a Baya extension into Pi.
 */
class PiRpcClient {
  private child: ChildProcessWithoutNullStreams | null = null;
  private buffer = "";
  private sequence = 0;
  private closing = false;
  private readonly pending = new Map<RpcId, RpcPending>();

  constructor(
    private readonly options: {
      cwd: string;
      name: string;
      sessionId: string;
      onEvent: (event: JsonObject) => void;
      onClosed: (error: Error) => void;
    },
  ) {}

  async start(): Promise<void> {
    if (this.child) return;
    const plan = spawnPlan("pi", piSpawnArgs(this.options));
    this.closing = false;
    const child = spawn(plan.command, plan.prefixArgs, {
      cwd: this.options.cwd,
      env: { ...process.env, BAYA_MANAGED_AGENT: "pi" },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
    });
    this.child = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.receive(chunk));
    child.stderr.on("data", (chunk: Buffer) => process.stderr.write(chunk));
    child.on("error", (error) => this.lost(error));
    child.on("exit", (code) => {
      if (!this.closing) {
        this.lost(new Error(`Pi RPC stopped (${code ?? "signal"}).`));
      }
    });
  }

  request(
    type: string,
    payload: JsonObject = {},
    timeoutMs = 30_000,
  ): Promise<unknown> {
    if (!this.child?.stdin.writable) {
      return Promise.reject(new Error("Pi RPC is not connected."));
    }
    const id = `baya-${++this.sequence}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Pi did not answer ${type} in time.`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.child!.stdin.write(JSON.stringify({ id, type, ...payload }) + "\n");
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("Could not send to Pi."));
      }
    });
  }

  write(payload: JsonObject): void {
    if (!this.child?.stdin.writable) return;
    this.child.stdin.write(JSON.stringify(payload) + "\n");
  }

  close(): void {
    this.closing = true;
    const child = this.child;
    this.child = null;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Pi RPC closed."));
    }
    this.pending.clear();
    if (child) {
      try {
        child.stdin.end();
      } catch {
        // The process may have exited already.
      }
      try {
        child.kill("SIGTERM");
      } catch {
        // The process may have exited already.
      }
    }
  }

  private receive(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > 16 * 1024 * 1024) {
      this.lost(new Error("Pi sent an oversized RPC frame."));
      return;
    }
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).replace(/\r$/u, "");
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let frame: JsonObject;
      try {
        frame = record(JSON.parse(line));
      } catch {
        continue;
      }
      if (frame["type"] === "response" && typeof frame["id"] === "string") {
        const pending = this.pending.get(frame["id"]);
        if (!pending) continue;
        this.pending.delete(frame["id"]);
        clearTimeout(pending.timer);
        if (frame["success"] === false) {
          pending.reject(new Error(stringValue(frame["error"]) || "Pi rejected the command."));
        } else {
          pending.resolve(frame["data"]);
        }
        continue;
      }
      this.options.onEvent(frame);
    }
  }

  private lost(error: Error): void {
    if (!this.child) return;
    const child = this.child;
    this.child = null;
    try {
      child.kill("SIGTERM");
    } catch {
      // Already exited.
    }
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    if (!this.closing) this.options.onClosed(error);
  }
}

export interface PiSpawnOptions {
  cwd: string;
  name: string;
  sessionId: string;
}

export type RpcExtensionUiResponse =
  | { type: "extension_ui_response"; id: string; value: string }
  | { type: "extension_ui_response"; id: string; confirmed: boolean }
  | { type: "extension_ui_response"; id: string; cancelled: true };

/**
 * Pi is an ordinary child process. Baya never injects an extension path, so a
 * Pi installation used interactively remains independent from Baya.
 */
export function piSpawnArgs(options: PiSpawnOptions): string[] {
  return [
    "--mode",
    "rpc",
    "--approve",
    "--session-id",
    options.sessionId,
    "--name",
    options.name,
  ];
}

export function piExtensionUiResponse(
  message: Extract<ClientMessage, { type: "extension_ui_response" }>,
): RpcExtensionUiResponse | null {
  if ("cancelled" in message && message.cancelled) {
    return { type: "extension_ui_response", id: message.id, cancelled: true };
  }
  if ("confirmed" in message && typeof message.confirmed === "boolean") {
    return { type: "extension_ui_response", id: message.id, confirmed: message.confirmed };
  }
  if ("value" in message && typeof message.value === "string") {
    return { type: "extension_ui_response", id: message.id, value: message.value };
  }
  // A rich ask envelope belonged to the old in-Pi extension bridge. The
  // standalone RPC host must never forward an extension-specific payload.
  return null;
}

export interface PiRpcPort {
  start(): Promise<void>;
  request(
    type: string,
    payload?: Record<string, unknown>,
    timeoutMs?: number,
  ): Promise<unknown>;
  write(payload: Record<string, unknown>): void;
  close(): void;
}

export class PiAdapter implements AgentAdapter {
  readonly agent = "pi";
  private readonly rpc: PiRpcPort;
  private busy = false;
  private userId = "pi";
  private currentText = "";
  private currentThinking = new Map<number, string>();
  private assistantMessageSequence = 0;
  private sessionStartedAt = Date.now();
  private nativeSessionId: string;
  private model = "";
  private lastUsage: Usage | undefined;

  constructor(
    private readonly options: AdapterOptions,
    rpc?: PiRpcPort,
  ) {
    this.nativeSessionId = options.nativeSessionId || crypto.randomUUID();
    this.rpc = rpc ?? new PiRpcClient({
        cwd: options.cwd,
        name: options.name,
        sessionId: this.nativeSessionId,
        onEvent: (event) => this.receiveEvent(event),
        onClosed: (error) => options.onClosed?.(error),
      });
  }

  get isBusy(): boolean {
    return this.busy;
  }

  async start(): Promise<void> {
    await this.rpc.start();
    const state = record(await this.rpc.request("get_state"));
    this.captureState(state);
  }

  close(): void {
    this.rpc.close();
  }

  async handle(sender: PeerChannel, message: ClientMessage): Promise<void> {
    try {
      switch (message.type) {
        case "ping":
          sender.send({ type: "pong", in_reply_to: message.id });
          return;
        case "session_sync":
          await this.sync(sender, message.id);
          return;
        case "user_message":
          await this.prompt(message);
          return;
        case "cancel":
          await this.rpc.request("abort", {}, 120_000);
          sender.send({
            type: "cancelled",
            in_reply_to: message.id,
            target_id: message.target_id,
          });
          return;
        case "model_set":
          {
            const model = this.modelFromState({ model: await this.rpc.request("set_model", {
              provider: message.provider,
              modelId: message.model_id,
            }) });
            if (!model) throw new Error("Pi changed models but returned no model metadata.");
            this.model = model.name;
            this.options.onModel?.(this.model);
          }
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        case "thinking_set":
          await this.rpc.request("set_thinking_level", { level: message.level });
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        case "session_new":
          await this.newSession(sender, message.id);
          return;
        case "session_compact":
          await this.rpc.request("compact", {}, 120_000);
          sender.send({ type: "action_ok", action: message.type, in_reply_to: message.id });
          return;
        case "context_usage_get":
          await this.contextUsage(sender, message.id);
          return;
        case "list_models":
          await this.listModels(sender, message.id);
          return;
        case "commands_get":
          await this.commands(sender, message.id);
          return;
        case "sessions_inventory":
          sender.send({
            type: "sessions_inventory",
            in_reply_to: message.id,
            session_keys: this.nativeSessionId ? [await this.sessionKey()] : [],
            scanned_at: Date.now(),
            complete: true,
          });
          return;
        case "extension_ui_response":
          {
            const response = piExtensionUiResponse(message);
            if (!response) {
              sender.send({
                type: "error",
                code: "invalid_message",
                in_reply_to: message.id,
                message: "This extension response has no RPC-compatible value.",
              });
              return;
            }
            this.rpc.write({ ...response });
          }
          return;
        case "queued_message_set":
        case "queued_message_clear":
          sender.send({
            type: "error",
            code: "unsupported_type",
            in_reply_to: message.id,
            message: "Pi RPC mode does not expose editable queued messages.",
          });
          return;
        case "approve_tool":
          sender.send({
            type: "error",
            code: "unsupported_type",
            in_reply_to: message.id,
            message: "Pi RPC handles tool approval through its native extension prompt.",
          });
          return;
        default:
          sender.send({
            type: "error",
            code: "unsupported_type",
            in_reply_to: message.id,
            message: `Pi does not support ${message.type}.`,
          });
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : "Pi request failed.";
      if (
        message.type === "model_set" ||
        message.type === "thinking_set" ||
        message.type === "session_new" ||
        message.type === "session_compact"
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
          code: "internal_error",
          in_reply_to: message.id,
          message: detail,
        });
      }
    }
  }

  /** Feed one decoded Pi RPC event. Public for deterministic adapter tests. */
  receiveEvent(event: Record<string, unknown>): void {
    this.onEvent(event);
  }

  private async prompt(message: Extract<ClientMessage, { type: "user_message" }>): Promise<void> {
    const images = (message.images ?? []).map((image) => ({
      type: "image",
      data: image.data,
      mimeType: image.mime,
    }));
    this.userId = message.id;
    this.currentText = "";
    this.currentThinking.clear();
    this.lastUsage = undefined;
    this.options.broadcast({
      type: "user_message",
      id: message.id,
      text: message.text,
      ...(message.images?.length ? { images: message.images } : {}),
      ...(message.streaming_behavior ? { streaming_behavior: message.streaming_behavior } : {}),
    });
    const result = record(await this.rpc.request("prompt", {
      message: message.text,
      ...(images.length ? { images } : {}),
      ...(message.streaming_behavior ? { streamingBehavior: message.streaming_behavior } : {}),
    }, 120_000));
    if (result["disposition"] === "handled") {
      this.finishTurn();
    }
  }

  private async sync(sender: PeerChannel, requestId: string): Promise<void> {
    const data = record(await this.rpc.request("get_messages", {}, 60_000));
    const frames = historyFrames({
      in_reply_to: requestId,
      session_started_at: this.sessionStartedAt,
      events: piHistoryEvents(array(data["messages"])),
      streaming: this.currentText
        ? { in_reply_to: this.userId, text: this.currentText }
        : null,
      truncated: false,
    });
    for (const frame of frames) sender.send(frame);
  }

  private onEvent(event: JsonObject): void {
    switch (event["type"]) {
      case "agent_start":
        this.lastUsage = undefined;
        this.setBusy(true);
        return;
      case "agent_settled":
        this.finishTurn();
        return;
      case "message_start":
        if (record(event["message"])["role"] === "assistant") {
          this.assistantMessageSequence++;
          this.currentText = "";
          this.currentThinking.clear();
        }
        return;
      case "message_update":
        this.onMessageUpdate(event);
        return;
      case "message_end": {
        const message = record(event["message"]);
        if (message["role"] !== "assistant") return;
        const finalText = contentText(message["content"]);
        if (finalText) this.currentText = finalText;
        const tokens = usage(message["usage"]);
        if (tokens) this.lastUsage = tokens;
        return;
      }
      case "tool_execution_start":
        this.options.broadcast({
          type: "tool_request",
          tool_call_id: stringValue(event["toolCallId"]),
          tool: stringValue(event["toolName"]),
          args: record(event["args"]),
        });
        return;
      case "tool_execution_end":
        this.options.broadcast({
          type: "tool_result",
          tool_call_id: stringValue(event["toolCallId"]),
          ...(event["isError"] === true
            ? { error: contentText(record(event["result"])["content"]) || "Tool call failed." }
            : { result: readableToolResult(event["result"]) }),
        });
        return;
      case "extension_ui_request": {
        const wire = this.extensionUi(event);
        if (wire) this.options.broadcast(wire);
        return;
      }
      case "auto_retry_start":
      case "auto_retry_end":
        this.setBusy(event["type"] === "auto_retry_start");
        return;
      case "compaction_start":
        this.setBusy(true);
        return;
      case "compaction_end":
        this.setBusy(false);
        if (event["result"]) {
          const result = record(event["result"]);
          this.options.broadcast({
            type: "compaction",
            summary: stringValue(result["summary"]),
            tokens_before: numberValue(result["tokensBefore"]),
          });
        }
    }
  }

  private onMessageUpdate(event: JsonObject): void {
    const update = record(event["assistantMessageEvent"]);
    const index = numberValue(update["contentIndex"]);
    switch (update["type"]) {
      case "text_delta": {
        const delta = stringValue(update["delta"]);
        this.currentText += delta;
        if (delta) {
          this.options.broadcast({
            type: "agent_chunk",
            in_reply_to: this.userId,
            delta,
          });
        }
        return;
      }
      case "text_end":
        if (!this.currentText) this.currentText = stringValue(update["content"]);
        return;
      case "thinking_start": {
        const id = this.thinkingId(index);
        this.currentThinking.set(index, "");
        this.options.broadcast({
          type: "agent_thinking",
          id,
          in_reply_to: this.userId,
          text: "",
          complete: false,
        });
        return;
      }
      case "thinking_delta": {
        const id = this.thinkingId(index);
        const text = (this.currentThinking.get(index) ?? "") + stringValue(update["delta"]);
        this.currentThinking.set(index, text);
        this.options.broadcast({
          type: "agent_thinking",
          id,
          in_reply_to: this.userId,
          text,
          complete: false,
        });
        return;
      }
      case "thinking_end": {
        const id = this.thinkingId(index);
        const text = stringValue(update["content"]) || this.currentThinking.get(index) || "";
        this.currentThinking.set(index, text);
        this.options.broadcast({
          type: "agent_thinking",
          id,
          in_reply_to: this.userId,
          text,
          complete: true,
        });
      }
    }
  }

  private extensionUi(event: JsonObject): ExtensionUiRequestWire | null {
    const id = stringValue(event["id"]);
    const method = event["method"];
    if (!id) return null;
    if (method === "select" && Array.isArray(event["options"])) {
      return {
        type: "extension_ui_request",
        id,
        method,
        title: stringValue(event["title"]),
        options: event["options"].map(String),
      };
    }
    if (method === "confirm") {
      return {
        type: "extension_ui_request",
        id,
        method,
        title: stringValue(event["title"]),
        message: stringValue(event["message"]),
      };
    }
    if (method === "input") {
      return {
        type: "extension_ui_request",
        id,
        method,
        title: stringValue(event["title"]),
        ...(typeof event["placeholder"] === "string"
          ? { placeholder: event["placeholder"] }
          : {}),
      };
    }
    if (method === "editor") {
      return {
        type: "extension_ui_request",
        id,
        method,
        title: stringValue(event["title"]),
        ...(typeof event["prefill"] === "string" ? { prefill: event["prefill"] } : {}),
      };
    }
    if (method === "notify") {
      const type = event["notifyType"];
      return {
        type: "extension_ui_request",
        id,
        method,
        message: stringValue(event["message"]),
        ...(type === "info" || type === "warning" || type === "error"
          ? { notify_type: type }
          : {}),
      };
    }
    return null;
  }

  private async contextUsage(sender: PeerChannel, requestId: string): Promise<void> {
    const data = record(await this.rpc.request("get_session_stats"));
    const context = record(data["contextUsage"]);
    sender.send({
      type: "context_usage",
      in_reply_to: requestId,
      source: "pi",
      tokens: typeof context["tokens"] === "number" ? context["tokens"] : null,
      context_window:
        typeof context["contextWindow"] === "number" ? context["contextWindow"] : null,
      percent: typeof context["percent"] === "number" ? context["percent"] : null,
    });
  }

  private async listModels(sender: PeerChannel, requestId: string): Promise<void> {
    const data = record(await this.rpc.request("get_available_models", {}, 60_000));
    const state = record(await this.rpc.request("get_state"));
    const current = this.modelFromState(state);
    const models = array(data["models"]).flatMap((raw): WireModel[] => {
      const model = record(raw);
      if (typeof model["id"] !== "string") return [];
      const reasoning = model["reasoning"] === true;
      return [{
        id: model["id"],
        name: stringValue(model["name"]) || model["id"],
        provider: stringValue(model["provider"]) || "pi",
        reasoning,
        thinking_levels: thinkingLevelsFromMap(
          model["thinkingLevelMap"],
          reasoning,
        ),
        context_window: numberValue(model["contextWindow"]),
        vision: array(model["input"]).includes("image"),
      }];
    });
    sender.send({
      type: "models_list",
      in_reply_to: requestId,
      models,
      ...(current ? { current } : {}),
    });
  }

  private async commands(sender: PeerChannel, requestId: string): Promise<void> {
    const data = record(await this.rpc.request("get_commands", {}, 60_000));
    const commands = array(data["commands"]).flatMap((raw): Array<{
      name: string;
      description?: string;
      source: "extension" | "prompt" | "skill";
    }> => {
      const item = record(raw);
      const source = item["source"];
      if (
        typeof item["name"] !== "string" ||
        (source !== "extension" && source !== "prompt" && source !== "skill")
      ) {
        return [];
      }
      return [{
        name: item["name"],
        ...(typeof item["description"] === "string"
          ? { description: item["description"] }
          : {}),
        source,
      }];
    });
    sender.send({ type: "commands_list", in_reply_to: requestId, commands });
  }

  private async newSession(sender: PeerChannel, requestId: string): Promise<void> {
    const result = record(await this.rpc.request("new_session", {}, 120_000));
    if (result["cancelled"] === true) {
      throw new Error("Pi canceled the new session.");
    }
    const state = record(await this.rpc.request("get_state"));
    this.captureState(state);
    this.sessionStartedAt = Date.now();
    sender.send({ type: "action_ok", action: "session_new", in_reply_to: requestId });
    sender.send({
      type: "session_history",
      in_reply_to: requestId,
      session_started_at: this.sessionStartedAt,
      events: [],
      streaming: null,
      eos: true,
      truncated: false,
    });
  }

  private captureState(state: JsonObject): void {
    this.nativeSessionId = stringValue(state["sessionId"]) || this.nativeSessionId;
    this.model = this.modelLabel(state);
    if (state["name"]) this.sessionStartedAt = Date.now();
    this.options.onModel?.(this.model);
    this.options.onNativeSessionId?.(this.nativeSessionId);
  }

  private modelFromState(state: JsonObject): WireModel | undefined {
    const model = record(state["model"]);
    if (typeof model["id"] !== "string") return undefined;
    const reasoning = model["reasoning"] === true;
    return {
      id: model["id"],
      name: stringValue(model["name"]) || model["id"],
      provider: stringValue(model["provider"]) || "pi",
      reasoning,
      thinking_levels: thinkingLevelsFromMap(
        model["thinkingLevelMap"],
        reasoning,
      ),
      context_window: numberValue(model["contextWindow"]),
      vision: array(model["input"]).includes("image"),
    };
  }

  private modelLabel(state: JsonObject): string {
    const model = this.modelFromState(state);
    return model?.name ?? "";
  }

  private thinkingId(index: number): string {
    return `pi-thinking-${this.nativeSessionId}-${this.assistantMessageSequence}-${index}`;
  }

  private finishTurn(): void {
    const userId = this.userId;
    const tokens = this.lastUsage;
    this.currentText = "";
    this.currentThinking.clear();
    this.lastUsage = undefined;
    this.setBusy(false);
    this.options.broadcast({
      type: "agent_done",
      in_reply_to: userId,
      ...(tokens ? { usage: tokens } : {}),
    });
  }

  private async sessionKey(): Promise<string> {
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(this.nativeSessionId),
    );
    return Buffer.from(digest).toString("base64url").slice(0, 16);
  }

  private setBusy(busy: boolean): void {
    if (this.busy === busy) return;
    this.busy = busy;
    this.options.onBusy?.(busy);
  }
}

/**
 * Convert Pi's persisted AgentMessage transcript into the Baya history
 * vocabulary while retaining the order of text, reasoning, and tool calls.
 */
export function piHistoryEvents(
  messages: unknown[],
  now: () => number = Date.now,
): SessionHistoryEvent[] {
  const events: SessionHistoryEvent[] = [];
  let lastUserId = "pi-history";
  for (const rawMessage of messages) {
    const message = record(rawMessage);
    const timestamp = numberValue(message["timestamp"]) || now();
    const role = message["role"];
    if (role === "user") {
      const id = stringValue(message["id"]) || `pi-user-${timestamp}-${events.length}`;
      lastUserId = id;
      const images = imageWire(message["content"]);
      events.push({
        ts: timestamp,
        type: "user_input",
        id,
        text: contentText(message["content"]),
        ...(images.length ? { images } : {}),
      });
      continue;
    }
    if (role === "assistant") {
      let text = "";
      const flushText = (): void => {
        if (!text) return;
        events.push({
          ts: timestamp,
          type: "agent_message",
          in_reply_to: lastUserId,
          text,
        });
        text = "";
      };
      for (const rawBlock of array(message["content"])) {
        const block = record(rawBlock);
        if (block["type"] === "text") {
          text += stringValue(block["text"]);
          continue;
        }
        flushText();
        if (block["type"] === "thinking") {
          const thinking = stringValue(block["thinking"]);
          if (thinking) {
            events.push({
              ts: timestamp,
              type: "agent_thinking",
              id: `pi-thinking-${timestamp}-${events.length}`,
              in_reply_to: lastUserId,
              text: thinking,
              complete: true,
            });
          }
        } else if (block["type"] === "toolCall") {
          events.push({
            ts: timestamp,
            type: "tool_request",
            tool_call_id: stringValue(block["id"]),
            tool: stringValue(block["name"]),
            args: record(block["arguments"]),
          });
        }
      }
      flushText();
      const tokens = usage(message["usage"]);
      if (tokens && events.length > 0) {
        const last = events.at(-1);
        if (last?.type === "agent_message" && last.in_reply_to === lastUserId) {
          last.usage = tokens;
        }
      }
      continue;
    }
    if (role === "toolResult") {
      const result = readableToolResult(message);
      events.push({
        ts: timestamp,
        type: "tool_result",
        tool_call_id: stringValue(message["toolCallId"]),
        ...(message["isError"] === true
          ? { error: contentText(message["content"]) || "Tool call failed." }
          : { result }),
      });
      continue;
    }
    if (role === "compactionSummary") {
      events.push({
        ts: timestamp,
        type: "compaction",
        summary: stringValue(message["summary"]),
        tokens_before: numberValue(message["tokensBefore"]),
      });
    }
  }
  return events;
}
