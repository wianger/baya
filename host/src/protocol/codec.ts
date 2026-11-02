import type { ClientMessage, ServerMessage } from "./types.ts";

const SERVER_TYPES = new Set<ServerMessage["type"]>([
  "pair_ok",
  "pair_error",
  "user_input",
  "queued_message_state",
  "agent_chunk",
  "agent_done",
  "agent_message",
  "tool_request",
  "tool_result",
  "error",
  "cancelled",
  "pong",
  "bye",
  "session_history",
  "context_usage",
  "sessions_inventory",
  // Plan/57 — interactive extension prompt (ask_user via pi-ask).
  "extension_ui_request",
]);

export class DecodeError extends Error {
  readonly code: "invalid_message" | "unsupported_type";

  constructor(code: DecodeError["code"], message: string) {
    super(message);
    this.code = code;
    this.name = "DecodeError";
  }
}

export function encodeClient(msg: ClientMessage): string {
  return `${JSON.stringify(msg)}\n`;
}

export function decodeServer(line: string): ServerMessage {
  let obj: unknown;
  try {
    obj = JSON.parse(line.trim());
  } catch (e) {
    throw new DecodeError("invalid_message", `not JSON: ${(e as Error).message}`);
  }
  if (
    !obj ||
    typeof obj !== "object" ||
    typeof (obj as Record<string, unknown>)["type"] !== "string"
  ) {
    throw new DecodeError("invalid_message", "missing 'type'");
  }
  const t = (obj as Record<string, unknown>)["type"] as string;
  if (!SERVER_TYPES.has(t as ServerMessage["type"])) {
    throw new DecodeError("unsupported_type", `unknown type: ${t}`);
  }
  return obj as ServerMessage;
}
