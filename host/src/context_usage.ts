import type { ServerMessage } from "./protocol/types.js";

export interface ContextUsageReader {
  getContextUsage?: () => { tokens?: number | null; contextWindow: number; percent?: number | null } | undefined;
  model?: { contextWindow: number };
}

export function contextUsageSnapshot(tokens: unknown, window: unknown) {
  const used = typeof tokens === "number" && Number.isFinite(tokens) && tokens >= 0 ? Math.floor(tokens) : null;
  const maximum = typeof window === "number" && Number.isFinite(window) && window > 0 ? Math.floor(window) : null;
  return { tokens: used, context_window: maximum, percent: used !== null && maximum !== null ? used * 100 / maximum : null };
}

export type ContextUsageSnapshot = ReturnType<typeof contextUsageSnapshot>;

export function handleContextUsage(
  ctx: ContextUsageReader | null,
  sender: { send(message: ServerMessage): void },
  id: string,
  fallback?: ContextUsageSnapshot,
): void {
  let usage: ReturnType<NonNullable<ContextUsageReader["getContextUsage"]>>;
  let window: number | undefined;
  try { usage = ctx?.getContextUsage?.(); window = usage?.contextWindow ?? ctx?.model?.contextWindow; }
  catch { /* A stale SDK context must not crash the relay callback. */ }
  let snapshot = contextUsageSnapshot(usage?.tokens, window);
  // Some SDK events expose a base context that can still describe the model
  // window but cannot reconstruct token usage. The last value captured from
  // session_start/message_end is the most recent reliable snapshot.
  if (snapshot.tokens === null && fallback?.tokens !== null && fallback?.tokens !== undefined) {
    snapshot = contextUsageSnapshot(
      fallback.tokens,
      snapshot.context_window ?? fallback.context_window,
    );
  }
  sender.send({ type: "context_usage", in_reply_to: id, source: "pi", ...snapshot });
}
