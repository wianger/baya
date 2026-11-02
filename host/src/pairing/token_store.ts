import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { BAYA_HOME, ensureBayaHome } from "../config.ts";

export interface PendingPairToken {
  token: string;
  room_id: string;
  expires_at: number;
  consumed_at: number | null;
}

export function pendingPairPath(): string {
  return join(BAYA_HOME, "runtime", "pair-request.json");
}

export function issuePendingPairToken(roomId: string, ttlMs = 600_000): PendingPairToken {
  const value: PendingPairToken = {
    // 128 bits: the token is single-use and expires within minutes.
    token: randomBytes(16).toString("base64url"),
    room_id: roomId,
    expires_at: Date.now() + Math.max(10_000, Math.min(ttlMs, 600_000)),
    consumed_at: null,
  };
  ensureBayaHome();
  mkdirSync(dirname(pendingPairPath()), { recursive: true, mode: 0o700 });
  writeFileSync(pendingPairPath(), `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  return value;
}

export function readPendingPairToken(): PendingPairToken | null {
  if (!existsSync(pendingPairPath())) return null;
  try {
    const value = JSON.parse(readFileSync(pendingPairPath(), "utf8")) as Partial<PendingPairToken>;
    if (
      typeof value.token !== "string" ||
      typeof value.room_id !== "string" ||
      typeof value.expires_at !== "number"
    )
      return null;
    return {
      token: value.token,
      room_id: value.room_id,
      expires_at: value.expires_at,
      consumed_at: typeof value.consumed_at === "number" ? value.consumed_at : null,
    };
  } catch {
    return null;
  }
}

export function consumePendingPairToken(
  token: string,
  roomId: string,
): "ok" | "expired" | "consumed" | "unknown" {
  const pending = readPendingPairToken();
  if (!pending || !sameSecret(pending.token, token) || pending.room_id !== roomId) {
    return "unknown";
  }
  if (pending.consumed_at !== null) return "consumed";
  if (Date.now() > pending.expires_at) return "expired";
  pending.consumed_at = Date.now();
  writeFileSync(pendingPairPath(), `${JSON.stringify(pending, null, 2)}\n`, { mode: 0o600 });
  return "ok";
}

export function clearPendingPairToken(): void {
  if (!existsSync(pendingPairPath())) return;
  const empty: PendingPairToken = {
    token: "",
    room_id: "",
    expires_at: 0,
    consumed_at: Date.now(),
  };
  writeFileSync(pendingPairPath(), `${JSON.stringify(empty, null, 2)}\n`, { mode: 0o600 });
}

/** Constant-time comparison so no one can time their way to a token. */
function sameSecret(expected: string, received: string): boolean {
  const a = Buffer.from(expected);
  const b = Buffer.from(received);
  return a.length > 0 && a.length === b.length && timingSafeEqual(a, b);
}
