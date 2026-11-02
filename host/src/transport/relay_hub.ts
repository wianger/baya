import { resolveRelayUrl, toWebSocketUrl } from "../config.ts";
import { getOrCreateEd25519Keypair } from "../pairing/storage.ts";
import { RelayClient, type RoomMeta } from "./relay_client.ts";

const MAX_BACKOFF_MS = 30_000;

export interface RoomHandlers {
  /** One routed envelope line addressed to this room. */
  onLine: (line: string) => void;
  /** A connection attempt for this room failed (it keeps retrying). */
  onFatal?: (error: Error) => void;
}

export interface RoomLink {
  isOpen(): boolean;
  /** Sends an outer envelope `{peer, ct}` from this room. */
  send(envelope: { peer: string; ct: string }): void;
  updateMeta(meta: Record<string, unknown>): void;
  close(): void;
}

interface RoomEntry extends RoomHandlers {
  meta: RoomMeta & Record<string, unknown>;
  conn: Connection;
}

/**
 * All sessions of this host share one authenticated relay socket: the first
 * room rides in the hello and the rest join with `room_open`. Inbound frames
 * carry `to_room`, outbound ones `from_room`.
 */
export class RelayHub {
  private readonly rooms = new Map<string, RoomEntry>();
  private shared: Connection | null = null;

  open(roomId: string, meta: RoomMeta, handlers: RoomHandlers): RoomLink {
    this.close(roomId);
    const conn = this.connectionFor();
    const entry: RoomEntry = { ...handlers, meta: { ...meta }, conn };
    this.rooms.set(roomId, entry);
    conn.add(roomId);
    return {
      isOpen: () => this.rooms.get(roomId)?.conn.isOpen(roomId) ?? false,
      send: (envelope) => this.rooms.get(roomId)?.conn.send(roomId, envelope),
      updateMeta: (patch) => {
        const current = this.rooms.get(roomId);
        if (!current) return;
        Object.assign(current.meta, patch);
        current.conn.control({ type: "room_meta_update", room_id: roomId, meta: patch });
      },
      close: () => {
        if (this.rooms.get(roomId) === entry) this.close(roomId);
      },
    };
  }

  /** Whether the shared relay socket is authenticated right now. */
  get connected(): boolean {
    return this.shared?.connected ?? false;
  }

  /** Room state the connection needs to (re)announce it. */
  entry(roomId: string): RoomEntry | undefined {
    return this.rooms.get(roomId);
  }

  private close(roomId: string): void {
    const entry = this.rooms.get(roomId);
    if (!entry) return;
    this.rooms.delete(roomId);
    entry.conn.remove(roomId, true);
    if (entry.conn === this.shared && entry.conn.size === 0) this.shared = null;
  }

  private connectionFor(): Connection {
    this.shared ??= new Connection(this);
    return this.shared;
  }
}

/** One relay socket serving one or more rooms, with its own reconnect loop. */
class Connection {
  private readonly rooms = new Set<string>();
  private client: RelayClient | null = null;
  private helloRoom: string | null = null;
  private connecting = false;
  private attempt = 0;
  private retry: ReturnType<typeof setTimeout> | null = null;
  /** Rooms sent in `room_open` that the relay has not confirmed yet. */
  private readonly pending = new Set<string>();

  private readonly hub: RelayHub;

  constructor(hub: RelayHub) {
    this.hub = hub;
  }

  get size(): number {
    return this.rooms.size;
  }

  get connected(): boolean {
    return this.client?.isOpen() ?? false;
  }

  /** Open for a room once the relay has acknowledged it. */
  isOpen(roomId: string): boolean {
    return (this.client?.isOpen() ?? false) && !this.pending.has(roomId);
  }

  add(roomId: string): void {
    this.rooms.add(roomId);
    if (this.client?.isOpen()) this.openRoom(roomId);
    else void this.connect();
  }

  remove(roomId: string, announce: boolean): void {
    if (!this.rooms.delete(roomId)) return;
    this.pending.delete(roomId);
    if (announce && this.client?.isOpen() && this.rooms.size > 0) {
      this.control({ type: "room_close", room_id: roomId });
    }
    if (this.rooms.size === 0) this.shutdown();
  }

  send(roomId: string, envelope: { peer: string; ct: string }): void {
    const client = this.client;
    if (!client || !this.isOpen(roomId)) return;
    const line = roomId === this.helloRoom ? envelope : { ...envelope, from_room: roomId };
    try {
      client.send(JSON.stringify(line));
    } catch {
      // A reconnect followed by session_sync recovers delivery.
    }
  }

  control(frame: Record<string, unknown>): void {
    this.client?.sendControl(frame);
  }

  private async connect(): Promise<void> {
    if (this.connecting || this.client || this.rooms.size === 0) return;
    this.connecting = true;
    const helloRoom = [...this.rooms][0]!;
    let client: RelayClient | null = null;
    try {
      const identity = await getOrCreateEd25519Keypair();
      client = new RelayClient(toWebSocketUrl(resolveRelayUrl().url), identity);
      await client.connect({
        roomId: helloRoom,
        roomMeta: this.hub.entry(helloRoom)?.meta ?? metaFallback(helloRoom),
      });
    } catch (error) {
      client?.close();
      this.connecting = false;
      const failure = error instanceof Error ? error : new Error("Relay connection failed.");
      for (const room of this.rooms) this.hub.entry(room)?.onFatal?.(failure);
      this.scheduleReconnect();
      return;
    }
    this.connecting = false;
    if (this.rooms.size === 0) {
      client.close();
      return;
    }
    this.client = client;
    this.helloRoom = helloRoom;
    this.attempt = 0;
    client.on("message", (line) => this.dispatch(line));
    client.on("close", () => {
      if (this.client !== client) return;
      this.client = null;
      this.helloRoom = null;
      this.pending.clear();
      this.scheduleReconnect();
    });
    client.on("error", () => {
      // close/reconnect owns recovery
    });
    if (!this.rooms.has(helloRoom)) this.control({ type: "room_close", room_id: helloRoom });
    for (const room of this.rooms) if (room !== helloRoom) this.openRoom(room);
  }

  private openRoom(roomId: string): void {
    const entry = this.hub.entry(roomId);
    if (!entry) return;
    this.pending.add(roomId);
    this.control({ type: "room_open", room_id: roomId, room_meta: entry.meta });
  }

  private dispatch(line: string): void {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    if (frame["type"] === "room_opened" && typeof frame["room_id"] === "string") {
      this.pending.delete(frame["room_id"]);
      return;
    }
    if (typeof frame["type"] === "string") return;
    const target = typeof frame["to_room"] === "string" ? frame["to_room"] : this.helloRoom;
    if (target && this.rooms.has(target)) this.hub.entry(target)?.onLine(line);
  }

  private scheduleReconnect(): void {
    if (this.retry || this.rooms.size === 0) return;
    const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** Math.min(this.attempt++, 6));
    this.retry = setTimeout(() => {
      this.retry = null;
      void this.connect();
    }, delay);
  }

  private shutdown(): void {
    if (this.retry) clearTimeout(this.retry);
    this.retry = null;
    this.pending.clear();
    const client = this.client;
    this.client = null;
    this.helloRoom = null;
    client?.close();
  }
}

function metaFallback(roomId: string): RoomMeta {
  return { name: roomId, cwd: "" };
}

let defaultHub: RelayHub | null = null;

/** The process-wide hub every session's relay host joins. */
export function relayHub(): RelayHub {
  defaultHub ??= new RelayHub();
  return defaultHub;
}
