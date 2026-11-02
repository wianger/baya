import { createPublicKey, randomBytes, verify } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { type WebSocket, WebSocketServer } from "ws";
import { getOrCreateEd25519Keypair, isPairedKey, listPeers } from "../pairing/storage.ts";

/** What a session's room tells phones about itself. */
export interface RoomMeta {
  name: string;
  cwd: string;
  model?: string;
}

export interface RoomHandlers {
  /** A sealed frame `ct` (base64) from the phone with key [peer]. */
  onEnvelope: (peer: string, ct: string) => void;
}

export interface RoomLink {
  /** Whether any phone is connected. */
  isOpen(): boolean;
  /** Sends a sealed frame from this room to every socket of [peer]. */
  send(envelope: { peer: string; ct: string }): void;
  updateMeta(meta: Record<string, unknown>): void;
  close(): void;
}

/**
 * Where phones connect to this host: WebSockets arriving through
 * `tailscale serve` at `…/baya-pair/<label>/direct`.
 *
 * A phone proves its Ed25519 key (hello/challenge/auth), then exchanges
 * sealed `{peer, room, ct}` envelopes with this host's rooms and receives
 * presence and room pushes. Room lists and presence go to paired phones
 * only; an unknown key may only send envelopes, which is how `pair_request`
 * arrives.
 */

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HELLO_TIMEOUT_MS = 5_000;
const PING_MS = 25_000;

interface Phone {
  socket: WebSocket;
  key: string;
  presence: boolean;
  rooms: boolean;
}

interface Room {
  meta: RoomMeta & { working?: boolean; thinking?: string };
  handlers: RoomHandlers;
  startedAt: number;
}

export class DirectServer {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 8 * 1024 * 1024 });
  private readonly phones = new Set<Phone>();
  private readonly rooms = new Map<string, Room>();
  private hostKey: Promise<string> | null = null;

  /** Accepts a WebSocket upgrade from one of the pairing listeners. */
  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    this.wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
  }

  open(roomId: string, meta: RoomMeta, handlers: RoomHandlers): RoomLink {
    const room: Room = { meta: { ...meta }, handlers, startedAt: Date.now() };
    this.rooms.set(roomId, room);
    void this.announce(roomId, room);
    return {
      isOpen: () => [...this.phones].some((phone) => phone.socket.readyState === phone.socket.OPEN),
      send: ({ peer, ct }) => this.deliver(peer, roomId, ct),
      updateMeta: (patch) => {
        Object.assign(room.meta, patch);
        void this.pushRooms({
          type: "room_meta_updated",
          room_id: roomId,
          meta: {
            ...(room.meta.model ? { model: room.meta.model } : {}),
            ...(room.meta.thinking ? { thinking: room.meta.thinking } : {}),
            working: room.meta.working === true,
          },
        });
      },
      close: () => {
        if (this.rooms.get(roomId) !== room) return;
        this.rooms.delete(roomId);
        void this.pushRooms({ type: "room_ended", room_id: roomId, since_ts: Date.now() });
      },
    };
  }

  /** Phones connected right now. */
  get connected(): number {
    return this.phones.size;
  }

  private key(): Promise<string> {
    this.hostKey ??= getOrCreateEd25519Keypair().then((identity) =>
      Buffer.from(identity.publicKey).toString("base64"),
    );
    return this.hostKey;
  }

  // ── connections ─────────────────────────────────────────────────────────

  private accept(socket: WebSocket): void {
    const timer = setTimeout(() => socket.terminate(), HELLO_TIMEOUT_MS);
    socket.once("message", (raw) => {
      let key: Buffer;
      try {
        const hello = JSON.parse(String(raw)) as { type?: string; pubkey?: string };
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
          const signature = Buffer.from(String(auth.sig), "base64");
          if (auth.type !== "auth" || !verify(null, nonce, publicKey, signature)) {
            throw new Error("bad signature");
          }
        } catch {
          socket.close();
          return;
        }
        this.register(socket, key.toString("base64"));
      });
    });
  }

  private register(socket: WebSocket, key: string): void {
    const phone: Phone = { socket, key, presence: false, rooms: false };
    this.phones.add(phone);
    const ping = setInterval(() => socket.ping(), PING_MS);
    socket.on("message", (raw) => void this.receive(phone, String(raw)));
    socket.on("close", () => {
      clearInterval(ping);
      this.phones.delete(phone);
    });
  }

  private async receive(phone: Phone, line: string): Promise<void> {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    const type = frame["type"];
    if (typeof type !== "string") {
      this.envelope(phone, frame);
      return;
    }
    // Everything below describes this computer: paired phones only.
    if (!isPairedKey(phone.key, await listPeers())) return;
    const hostKey = await this.key();
    const peers = Array.isArray(frame["peers"]) ? frame["peers"] : [];
    const asksForHost = peers.some((peer) => typeof peer === "string" && sameKey(peer, hostKey));
    switch (type) {
      case "subscribe_presence":
        phone.presence = asksForHost;
        if (asksForHost) this.send(phone, { type: "peer_online", peer: hostKey });
        return;
      case "presence_check":
        this.send(phone, {
          type: "presence",
          states: asksForHost ? [{ peer: hostKey, online: true }] : [],
        });
        return;
      case "subscribe_rooms":
        phone.rooms = phone.rooms || asksForHost;
        return;
      case "rooms_check":
        if (asksForHost) this.send(phone, { type: "rooms", peer: hostKey, rooms: this.roomList() });
        return;
      default:
        return;
    }
  }

  /** A phone's envelope for one of this host's rooms. */
  private envelope(phone: Phone, frame: Record<string, unknown>): void {
    const ct = frame["ct"];
    const roomId = typeof frame["room"] === "string" ? frame["room"] : "main";
    const room = this.rooms.get(roomId);
    if (typeof ct !== "string" || !room) return;
    room.handlers.onEnvelope(phone.key, ct);
  }

  /** This host's reply from [roomId] to every direct socket of [peer]. */
  private async deliver(peer: string, roomId: string, ct: string): Promise<void> {
    const hostKey = await this.key();
    const line = JSON.stringify({ peer: hostKey, room: roomId, to_room: "main", ct });
    for (const phone of this.phones) {
      if (sameKey(phone.key, peer) && phone.socket.readyState === phone.socket.OPEN) {
        phone.socket.send(line);
      }
    }
  }

  // ── room pushes ─────────────────────────────────────────────────────────

  private roomList(): Array<Record<string, unknown>> {
    return [...this.rooms].map(([roomId, room]) => this.roomFrame(roomId, room));
  }

  private roomFrame(roomId: string, room: Room): Record<string, unknown> {
    const { name, cwd, model, thinking, working } = room.meta;
    return {
      room_id: roomId,
      ...(name ? { name } : {}),
      ...(cwd ? { cwd } : {}),
      ...(model ? { model } : {}),
      ...(thinking ? { thinking } : {}),
      working: working === true,
      started_at: room.startedAt,
    };
  }

  private async announce(roomId: string, room: Room): Promise<void> {
    await this.pushRooms({ type: "room_announced", ...this.roomFrame(roomId, room) });
  }

  private async pushRooms(message: Record<string, unknown>): Promise<void> {
    if (![...this.phones].some((phone) => phone.rooms)) return;
    const frame = { ...message, peer: await this.key() };
    for (const phone of this.phones) if (phone.rooms) this.send(phone, frame);
  }

  private send(phone: Phone, message: object): void {
    if (phone.socket.readyState === phone.socket.OPEN) phone.socket.send(JSON.stringify(message));
  }
}

function sameKey(a: string, b: string): boolean {
  return Buffer.from(a, "base64").equals(Buffer.from(b, "base64"));
}

let instance: DirectServer | null = null;

/** The process-wide direct endpoint every room registers with. */
export function directServer(): DirectServer {
  instance ??= new DirectServer();
  return instance;
}
