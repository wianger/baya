import { hostname } from "node:os";
import { RpcError } from "../acp/jsonrpc.ts";
import { addPeer } from "./storage.ts";
import { consumePendingPairToken } from "./token_store.ts";

const FAILURES = {
  expired: "This pairing code has expired. Run `baya pair` again.",
  consumed: "This pairing code was already used. Run `baya pair` again.",
  unknown: "This pairing code was not issued by this computer.",
} as const;

/**
 * `_baya/pair`: trades a one-time code for a lasting pairing of [key], the
 * phone key the WebSocket handshake already proved.
 */
export async function pairPhone(
  key: string,
  token: unknown,
  deviceName: unknown,
): Promise<{ hostname: string }> {
  if (typeof token !== "string" || typeof deviceName !== "string") {
    throw RpcError.invalidParams("Pairing needs a token and a device name.");
  }
  const status = consumePendingPairToken(token);
  if (status !== "ok") throw new RpcError(-32000, FAILURES[status], { reason: `token_${status}` });
  await addPeer({
    name: deviceName.trim().slice(0, 80) || "Phone",
    remote_epk: key,
    paired_at: new Date().toISOString(),
  });
  return { hostname: hostname() };
}
