import { createPublicKey, randomBytes, verify } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname } from "node:path";
import { type WebSocket, WebSocketServer } from "ws";

/**
 * The relay, built into the host.
 *
 * Speaks the same protocol as the standalone Rust relay (relay/), so phones
 * and hosts need no changes: Ed25519 hello/challenge/auth, `{peer, room, ct}`
 * envelopes with `from_room`/`to_room`, `room_open`/`room_close`, presence
 * and room subscriptions, and the `/mesh/<hash>` store. On a Tailscale setup
 * `tailscale serve` exposes it, so the phone reaches the computer directly
 * and no separate relay service exists.
 */

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const MAX_CT_BASE64 = Math.ceil((4 * 1024 * 1024 * 4) / 3);
const HELLO_TIMEOUT_MS = 5_000;
const PING_MS = 25_000;

interface RoomMeta {
  room_id: string;
  name?: string;
  cwd?: string;
  model?: string;
  thinking?: string;
  working: boolean;
  started_at: number;
}

interface Conn {
  id: number;
  socket: WebSocket;
  peer: string;
  helloRoom: string;
  rooms: Map<string, RoomMeta>;
}

interface MeshRecord {
  version: number;
  blob: string;
  sig: string;
  updated_at: number;
}

export class Hub {
  private readonly conns = new Set<Conn>();
  private readonly presenceSubs = new Map<string, Set<string>>(); // subscriber -> peers
  private readonly roomSubs = new Map<string, Set<string>>();
  private readonly lastOffline = new Map<string, number>();
  private mesh: Record<string, MeshRecord> = {};
  private nextId = 1;
  private http: Server | null = null;
  private readonly meshFile: string | null;

  constructor(options: { meshFile?: string } = {}) {
    this.meshFile = options.meshFile ?? null;
    if (this.meshFile && existsSync(this.meshFile)) {
      try {
        this.mesh = JSON.parse(readFileSync(this.meshFile, "utf8")) as Record<string, MeshRecord>;
      } catch {
        this.mesh = {};
      }
    }
  }

  /** Binds `host:port`; rejects with EADDRINUSE when another hub owns it. */
  async listen(port: number, host = "127.0.0.1"): Promise<void> {
    const http = createServer((request, response) => this.httpRequest(request, response));
    const wss = new WebSocketServer({ server: http, maxPayload: 8 * 1024 * 1024 });
    wss.on("connection", (socket) => this.accept(socket));
    // `ws` re-emits the server's listen errors; `listen` reports them below.
    wss.on("error", () => {});
    await new Promise<void>((resolve, reject) => {
      http.once("error", reject);
      http.listen(port, host, () => resolve());
    });
    this.http = http;
  }

  close(): void {
    for (const conn of this.conns) conn.socket.terminate();
    this.http?.close();
    this.http = null;
  }

  // ── connections ─────────────────────────────────────────────────────────

  private accept(socket: WebSocket): void {
    const timer = setTimeout(() => socket.terminate(), HELLO_TIMEOUT_MS);
    socket.once("message", (raw) => {
      let hello: { type?: string; pubkey?: string; room_id?: string; room_meta?: unknown };
      let key: Buffer;
      try {
        hello = JSON.parse(String(raw));
        key = Buffer.from(String(hello.pubkey), "base64");
        if (hello.type !== "hello" || key.length !== 32) throw new Error("bad hello");
      } catch {
        socket.terminate();
        return;
      }
      const nonce = randomBytes(32);
      socket.send(JSON.stringify({ type: "challenge", nonce: nonce.toString("base64") }));
      socket.once("message", (authRaw) => {
        clearTimeout(timer);
        try {
          const auth = JSON.parse(String(authRaw)) as { type?: string; sig?: string };
          const publicKey = createPublicKey({
            key: Buffer.concat([SPKI_ED25519_PREFIX, key]),
            format: "der",
            type: "spki",
          });
          if (
            auth.type !== "auth" ||
            !verify(null, nonce, publicKey, Buffer.from(String(auth.sig), "base64"))
          ) {
            throw new Error("bad signature");
          }
        } catch {
          socket.close();
          return;
        }
        const roomId = typeof hello.room_id === "string" && hello.room_id ? hello.room_id : "main";
        this.register(socket, key.toString("base64"), roomId, hello.room_meta);
      });
    });
  }

  private register(socket: WebSocket, peer: string, helloRoom: string, meta: unknown): void {
    const wasOnline = this.isOnline(peer);
    const conn: Conn = { id: this.nextId++, socket, peer, helloRoom, rooms: new Map() };
    this.conns.add(conn);
    this.openRoom(conn, helloRoom, meta);
    if (!wasOnline) this.notifyPresence(peer, { type: "peer_online", peer });

    const ping = setInterval(() => socket.ping(), PING_MS);
    socket.on("message", (raw) => this.receive(conn, String(raw)));
    socket.on("close", () => {
      clearInterval(ping);
      this.conns.delete(conn);
      for (const room of [...conn.rooms.keys()]) this.closeRoom(conn, room);
      this.presenceSubs.delete(peer);
      this.roomSubs.delete(peer);
      if (!this.isOnline(peer)) {
        const now = Date.now();
        this.lastOffline.set(peer, now);
        this.notifyPresence(peer, { type: "peer_offline", peer, since_ts: now });
      }
    });
  }

  private receive(conn: Conn, line: string): void {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    const type = frame["type"];
    if (typeof type !== "string") {
      this.forward(conn, frame);
      return;
    }
    const peers = Array.isArray(frame["peers"])
      ? frame["peers"].filter((value): value is string => typeof value === "string")
      : [];
    switch (type) {
      case "subscribe_presence":
        this.presenceSubs.set(conn.peer, new Set(peers));
        for (const peer of peers) {
          if (this.isOnline(peer)) this.send(conn.socket, { type: "peer_online", peer });
        }
        return;
      case "unsubscribe_presence":
        for (const peer of peers) this.presenceSubs.get(conn.peer)?.delete(peer);
        return;
      case "presence_check":
        this.send(conn.socket, {
          type: "presence",
          states: peers.map((peer) => {
            const online = this.isOnline(peer);
            const since = this.lastOffline.get(peer);
            return { peer, online, ...(!online && since ? { since_ts: since } : {}) };
          }),
        });
        return;
      case "subscribe_rooms":
        this.roomSubs.set(conn.peer, new Set([...(this.roomSubs.get(conn.peer) ?? []), ...peers]));
        return;
      case "unsubscribe_rooms":
        for (const peer of peers) this.roomSubs.get(conn.peer)?.delete(peer);
        return;
      case "rooms_check":
        for (const peer of peers) {
          this.send(conn.socket, { type: "rooms", peer, rooms: this.roomsOf(peer) });
        }
        return;
      case "room_meta_update":
        this.updateMeta(conn, frame);
        return;
      case "room_open": {
        const room = frame["room_id"];
        if (typeof room !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(room)) return;
        if (!conn.rooms.has(room)) this.openRoom(conn, room, frame["room_meta"]);
        this.send(conn.socket, { type: "room_opened", room_id: room });
        return;
      }
      case "room_close": {
        const room = frame["room_id"];
        if (typeof room === "string") this.closeRoom(conn, room);
        return;
      }
      default:
        return;
    }
  }

  /** Envelope: deliver to every connection serving (peer, room) but the sender. */
  private forward(conn: Conn, frame: Record<string, unknown>): void {
    const dest = frame["peer"];
    const ct = frame["ct"];
    if (typeof dest !== "string" || typeof ct !== "string" || ct.length > MAX_CT_BASE64) return;
    const destRoom = typeof frame["room"] === "string" ? frame["room"] : "main";
    const fromRoom =
      typeof frame["from_room"] === "string" && conn.rooms.has(frame["from_room"])
        ? frame["from_room"]
        : conn.helloRoom;
    const line = JSON.stringify({ peer: conn.peer, room: fromRoom, to_room: destRoom, ct });
    for (const target of this.conns) {
      if (target !== conn && target.peer === dest && target.rooms.has(destRoom)) {
        target.socket.send(line);
      }
    }
  }

  // ── rooms ───────────────────────────────────────────────────────────────

  private openRoom(conn: Conn, roomId: string, raw: unknown): void {
    const first = !this.hasRoom(conn.peer, roomId);
    const meta = roomMeta(roomId, raw);
    conn.rooms.set(roomId, meta);
    if (first) this.notifyRooms(conn.peer, { type: "room_announced", peer: conn.peer, ...meta });
  }

  private closeRoom(conn: Conn, roomId: string): void {
    if (!conn.rooms.delete(roomId)) return;
    if (!this.hasRoom(conn.peer, roomId)) {
      this.notifyRooms(conn.peer, {
        type: "room_ended",
        peer: conn.peer,
        room_id: roomId,
        since_ts: Date.now(),
      });
    }
  }

  private updateMeta(conn: Conn, frame: Record<string, unknown>): void {
    const roomId = typeof frame["room_id"] === "string" ? frame["room_id"] : conn.helloRoom;
    const patch = (frame["meta"] ?? {}) as Record<string, unknown>;
    let current: RoomMeta | undefined;
    for (const other of this.conns) {
      const meta = other.peer === conn.peer ? other.rooms.get(roomId) : undefined;
      if (!meta) continue;
      for (const field of ["model", "thinking"] as const) {
        if (field in patch) {
          const value = patch[field];
          if (typeof value === "string") meta[field] = value;
          else delete meta[field];
        }
      }
      if (typeof patch["working"] === "boolean") meta.working = patch["working"];
      current = meta;
    }
    if (!current) return;
    this.notifyRooms(conn.peer, {
      type: "room_meta_updated",
      peer: conn.peer,
      room_id: roomId,
      meta: {
        ...(current.model ? { model: current.model } : {}),
        ...(current.thinking ? { thinking: current.thinking } : {}),
        working: current.working,
      },
    });
  }

  private roomsOf(peer: string): RoomMeta[] {
    const rooms = new Map<string, RoomMeta>();
    for (const conn of this.conns) {
      if (conn.peer === peer) for (const [id, meta] of conn.rooms) rooms.set(id, meta);
    }
    return [...rooms.values()];
  }

  private hasRoom(peer: string, roomId: string): boolean {
    for (const conn of this.conns) if (conn.peer === peer && conn.rooms.has(roomId)) return true;
    return false;
  }

  private isOnline(peer: string): boolean {
    for (const conn of this.conns) if (conn.peer === peer) return true;
    return false;
  }

  private notifyPresence(peer: string, message: object): void {
    this.notify(this.presenceSubs, peer, message);
  }

  private notifyRooms(peer: string, message: object): void {
    this.notify(this.roomSubs, peer, message);
  }

  private notify(subs: Map<string, Set<string>>, peer: string, message: object): void {
    for (const [subscriber, peers] of subs) {
      if (!peers.has(peer)) continue;
      for (const conn of this.conns) if (conn.peer === subscriber) this.send(conn.socket, message);
    }
  }

  private send(socket: WebSocket, message: object): void {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  }

  // ── HTTP: /health and /mesh/<hash> ───────────────────────────────────────

  private httpRequest(request: IncomingMessage, response: ServerResponse): undefined {
    this.handleHttp(request, response);
  }

  private handleHttp(request: IncomingMessage, response: ServerResponse): unknown {
    const url = new URL(request.url ?? "/", "http://hub");
    const reply = (status: number, body?: object) => {
      response.writeHead(status, body ? { "content-type": "application/json" } : {});
      response.end(body ? JSON.stringify(body) : "");
    };
    if (url.pathname === "/health") {
      response.writeHead(200);
      return void response.end("OK");
    }
    const match = /\/mesh\/([0-9a-fA-F]{64})$/.exec(url.pathname);
    if (!match) return reply(404);
    const hash = match[1]!.toLowerCase();
    if (request.method === "GET") {
      const record = this.mesh[hash];
      if (!record) return reply(404);
      const since = Number(url.searchParams.get("since"));
      if (url.searchParams.has("since") && record.version <= since) return reply(304);
      return reply(200, record);
    }
    if (request.method !== "POST") return reply(405);
    const chunks: Buffer[] = [];
    let size = 0;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size <= 512 * 1024) chunks.push(chunk);
    });
    request.on("end", () => {
      if (size > 512 * 1024) return reply(413);
      let body: { blob?: unknown; sig?: unknown; version?: unknown };
      try {
        body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        return reply(400, { error: "invalid json" });
      }
      // Phones verify the owner signature when they read it back.
      const version = meshVersion(body.blob);
      if (typeof body.blob !== "string" || typeof body.sig !== "string" || version === null) {
        return reply(400, { error: "invalid envelope" });
      }
      const current = this.mesh[hash];
      if (current && version <= current.version) return reply(409);
      const record = { version, blob: body.blob, sig: body.sig, updated_at: Date.now() };
      this.mesh[hash] = record;
      this.persistMesh();
      return reply(200, { version, updated_at: record.updated_at });
    });
  }

  private persistMesh(): void {
    if (!this.meshFile) return;
    mkdirSync(dirname(this.meshFile), { recursive: true, mode: 0o700 });
    writeFileSync(this.meshFile, JSON.stringify(this.mesh), { mode: 0o600 });
  }
}

function roomMeta(roomId: string, raw: unknown): RoomMeta {
  const meta = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const text = (key: string) => (typeof meta[key] === "string" ? (meta[key] as string) : undefined);
  const name = text("name");
  const cwd = text("cwd");
  const model = text("model");
  const thinking = text("thinking");
  return {
    room_id: roomId,
    ...(name ? { name } : {}),
    ...(cwd ? { cwd } : {}),
    ...(model ? { model } : {}),
    ...(thinking ? { thinking } : {}),
    working: meta["working"] === true,
    started_at: Date.now(),
  };
}

/** The `version` inside a base64 canonical-JSON mesh blob. */
function meshVersion(blob: unknown): number | null {
  if (typeof blob !== "string") return null;
  try {
    const parsed = JSON.parse(Buffer.from(blob, "base64").toString("utf8")) as {
      version?: unknown;
    };
    return typeof parsed.version === "number" && Number.isInteger(parsed.version)
      ? parsed.version
      : null;
  } catch {
    return null;
  }
}
