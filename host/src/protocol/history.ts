import type { ServerMessage } from "./types.js";

type HistoryFrame = Extract<ServerMessage, { type: "session_history" }>;
type HistorySnapshot = Omit<HistoryFrame, "type" | "eos">;
const TARGET_BYTES = 1024 * 1024;
// The relay checks decoded payload bytes; keep metadata/padding headroom.
const MAX_BYTES = 4 * 1024 * 1024 - 1024;
const bytes = (value: unknown): number => Buffer.byteLength(JSON.stringify(value), "utf8");

/** Build the entire reply before sending, so an oversized individual event
 * cannot leave a receiver waiting forever for the last fragment. */
export function historyFrames(snapshot: HistorySnapshot): HistoryFrame[] {
  const { events, streaming, ...meta } = snapshot;
  const frames: HistoryFrame[] = [];
  let batch: HistoryFrame["events"] = [];
  const headerBytes = bytes({ type: "session_history", ...meta, events: [], eos: false });
  let size = headerBytes;
  for (const event of events) {
    const eventBytes = bytes(event);
    if (headerBytes + eventBytes > MAX_BYTES) {
      throw new Error("A history event is too large to synchronize. Reduce the attachment or tool output first.");
    }
    if (batch.length && size + eventBytes + 1 > TARGET_BYTES) {
      frames.push({ type: "session_history", ...meta, events: batch, eos: false });
      batch = [];
      size = headerBytes;
    }
    size += eventBytes + (batch.length ? 1 : 0);
    batch.push(event);
  }
  const final: HistoryFrame = { type: "session_history", ...meta, events: batch, eos: true,
    ...("streaming" in snapshot ? { streaming } : {}) };
  // A large live cursor gets its own final frame, rather than being repeated
  // in every history fragment or exceeding the size limit with the last batch.
  if (batch.length && bytes(final) > TARGET_BYTES && streaming != null) {
    frames.push({ type: "session_history", ...meta, events: batch, eos: false });
    final.events = [];
  }
  if (bytes(final) > MAX_BYTES) throw new Error("The current response is too large to synchronize.");
  frames.push(final);
  return frames;
}
