/**
 * A transport-agnostic JSON-RPC 2.0 peer: both sides of ACP send requests
 * and notifications, so one class serves the phone link and the agent pipe.
 */

export type RpcId = number | string;
export type Json = Record<string, unknown>;

export interface RpcErrorShape {
  code: number;
  message: string;
  data?: unknown;
}

export class RpcError extends Error {
  readonly code: number;
  readonly data: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = "RpcError";
    this.code = code;
    this.data = data;
  }

  toJSON(): RpcErrorShape {
    return {
      code: this.code,
      message: this.message,
      ...(this.data === undefined ? {} : { data: this.data }),
    };
  }

  static methodNotFound(method: string): RpcError {
    return new RpcError(-32601, `Method not found: ${method}`);
  }

  static invalidParams(message: string): RpcError {
    return new RpcError(-32602, message);
  }

  static notFound(message: string): RpcError {
    return new RpcError(-32002, message);
  }
}

export type RequestHandler = (method: string, params: Json, id: RpcId) => Promise<unknown>;
export type NotificationHandler = (method: string, params: Json) => void;

interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

export class JsonRpcPeer {
  private sequence = 0;
  private readonly pending = new Map<RpcId, Pending>();
  private closedWith: Error | null = null;

  private readonly write: (message: Json) => void;
  private readonly onRequest: RequestHandler;
  private readonly onNotification: NotificationHandler;

  constructor(options: {
    write: (message: Json) => void;
    onRequest: RequestHandler;
    onNotification: NotificationHandler;
  }) {
    this.write = options.write;
    this.onRequest = options.onRequest;
    this.onNotification = options.onNotification;
  }

  get closed(): boolean {
    return this.closedWith !== null;
  }

  request<T = Json>(method: string, params: Json): Promise<T> {
    if (this.closedWith) return Promise.reject(this.closedWith);
    const id = ++this.sequence;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  /** The id the next [request] will use, so a caller can cancel it later. */
  get lastRequestId(): RpcId {
    return this.sequence;
  }

  notify(method: string, params: Json): void {
    if (!this.closedWith) this.write({ jsonrpc: "2.0", method, params });
  }

  /** Feeds one decoded message from the transport. */
  receive(message: unknown): void {
    if (!isObject(message)) return;
    const { id, method } = message;
    if (typeof method === "string") {
      const params = isObject(message["params"]) ? message["params"] : {};
      if (id === undefined || id === null) {
        this.onNotification(method, params);
        return;
      }
      if (typeof id !== "string" && typeof id !== "number") return;
      this.onRequest(method, params, id).then(
        (result) => {
          if (!this.closedWith) this.write({ jsonrpc: "2.0", id, result: result ?? null });
        },
        (error: unknown) => {
          if (!this.closedWith)
            this.write({ jsonrpc: "2.0", id, error: toRpcError(error).toJSON() });
        },
      );
      return;
    }
    if (typeof id !== "string" && typeof id !== "number") return;
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    if (isObject(message["error"])) {
      const error = message["error"];
      pending.reject(
        new RpcError(
          typeof error["code"] === "number" ? error["code"] : -32603,
          typeof error["message"] === "string" ? error["message"] : "Request failed.",
          error["data"],
        ),
      );
    } else {
      pending.resolve(message["result"]);
    }
  }

  /** Fails every outstanding request; later calls reject immediately. */
  close(error: Error): void {
    if (this.closedWith) return;
    this.closedWith = error;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

export function toRpcError(error: unknown): RpcError {
  if (error instanceof RpcError) return error;
  return new RpcError(-32603, error instanceof Error ? error.message : String(error));
}

export function isObject(value: unknown): value is Json {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Splits a byte stream into newline-delimited JSON messages. */
export class NdjsonDecoder {
  private buffer = "";

  push(chunk: string, emit: (message: unknown) => void, onGarbage?: (line: string) => void): void {
    this.buffer += chunk;
    for (
      let newline = this.buffer.indexOf("\n");
      newline >= 0;
      newline = this.buffer.indexOf("\n")
    ) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        onGarbage?.(line);
        continue;
      }
      emit(parsed);
    }
  }
}
