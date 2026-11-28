import type { Json, RpcId } from "./jsonrpc.ts";

/** A connected phone, as a conversation talks to it. */
export interface PhoneLink {
  readonly key: string;
  notify(method: string, params: Json): void;
  /** Sends a request; `id` lets the caller withdraw it with `$/cancel_request`. */
  ask(method: string, params: Json): { id: RpcId; result: Promise<unknown> };
}
