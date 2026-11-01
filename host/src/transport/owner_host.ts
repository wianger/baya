import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import { canonicalizeEd25519PublicKey } from "../mesh/encoding.js";
import { getOrCreateEd25519Keypair, listPeers, type PeerRecord } from "../pairing/storage.js";
import { resolveRelayUrl, toWebSocketUrl } from "../config.js";
import { RelayClient, type RoomMeta } from "./relay_client.js";
import type { PeerChannel } from "./peer_channel.js";

function canonicalKey(value: unknown): string | null {
  if (typeof value !== "string" || !value) return null;
  try {
    return canonicalizeEd25519PublicKey(value);
  } catch {
    return null;
  }
}

export function isPairedOwner(
  peer: unknown,
  owners: ReadonlyArray<Pick<PeerRecord, "remote_epk">>,
): boolean {
  const key = canonicalKey(peer);
  return key !== null && owners.some((owner) => canonicalKey(owner.remote_epk) === key);
}

export interface OwnerHostOptions {
  roomId: string;
  roomMeta: RoomMeta;
  onMessage: (sender: PeerChannel, message: ClientMessage) => void;
  onFatal?: (error: Error) => void;
}

/**
 * One relay room owned by the standalone Baya host. Pair requests from an
 * unknown mobile key are admitted only so the pairing service can validate the
 * one-time token; every other frame must come from a persisted owner.
 */
export class OwnerRelayHost {
  private relay: RelayClient | null = null;
  private stopped = false;
  private reconnect: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private readonly attached = new Set<string>();
  private inbound: Promise<void> = Promise.resolve();
  private outbound: Promise<void> = Promise.resolve();
  private readonly meta: RoomMeta & { working?: boolean };

  constructor(private readonly options: OwnerHostOptions) {
    this.meta = { ...options.roomMeta };
  }

  async start(): Promise<void> {
    this.stopped = false;
    try {
      await this.connect();
    } catch (error) {
      // Relay availability and the local agent host are independent. Keep the
      // host alive and reconnect in the background so a sleeping laptop, VPN
      // transition, or relay outage does not make local sessions unusable.
      this.options.onFatal?.(
        error instanceof Error ? error : new Error("Initial relay connection failed."),
      );
      this.scheduleReconnect();
    }
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnect) clearTimeout(this.reconnect);
    this.reconnect = null;
    this.relay?.close();
    this.relay = null;
    this.attached.clear();
  }

  broadcast(message: ServerMessage): void {
    this.queueSend([...this.attached], message);
  }

  sendTo(peer: string, message: ServerMessage): void {
    this.queueSend([peer], message);
  }

  updateMeta(meta: { model?: string; working?: boolean }): void {
    Object.assign(this.meta, meta);
    this.relay?.sendControl({
      type: "room_meta_update",
      room_id: this.options.roomId,
      meta,
    });
  }

  private async connect(): Promise<void> {
    const identity = await getOrCreateEd25519Keypair();
    if (this.stopped) return;
    const relay = new RelayClient(toWebSocketUrl(resolveRelayUrl().url), identity);
    try {
      await relay.connect({ roomId: this.options.roomId, roomMeta: this.meta });
    } catch (error) {
      relay.close();
      throw error;
    }
    if (this.stopped) {
      relay.close();
      return;
    }
    this.relay = relay;
    this.attempt = 0;
    relay.on("message", (line) => {
      this.inbound = this.inbound
        .then(() => this.receive(line))
        .catch((error: unknown) => {
          process.stderr.write(
            `[baya] Ignored invalid mobile frame: ${
              error instanceof Error ? error.name : "error"
            }\n`,
          );
        });
    });
    relay.on("close", () => {
      if (this.relay !== relay || this.stopped) return;
      this.relay = null;
      this.scheduleReconnect();
    });
    relay.on("error", () => {
      // close/reconnect owns recovery
    });
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnect) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(this.attempt++, 6));
    this.reconnect = setTimeout(() => {
      this.reconnect = null;
      void this.connect().catch((error: unknown) => {
        this.options.onFatal?.(
          error instanceof Error ? error : new Error("Relay reconnect failed."),
        );
        this.scheduleReconnect();
      });
    }, delay);
  }

  private async receive(line: string): Promise<void> {
    let outer: Record<string, unknown>;
    try {
      outer = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    if (typeof outer["peer"] !== "string" || typeof outer["ct"] !== "string") return;

    let message: unknown;
    try {
      message = JSON.parse(Buffer.from(outer["ct"], "base64").toString("utf8"));
    } catch {
      return;
    }
    if (
      !message ||
      typeof message !== "object" ||
      typeof (message as { type?: unknown }).type !== "string"
    ) {
      return;
    }

    const peer = outer["peer"];
    const sender: PeerChannel = {
      remotePeerId: peer,
      send: (reply) => this.queueSend([peer], reply),
    };

    if ((message as { type: string }).type === "pair_request") {
      this.options.onMessage(sender, message as ClientMessage);
      return;
    }

    if (!isPairedOwner(peer, await listPeers())) {
      this.sendTo(peer, {
        type: "error",
        code: "unknown_peer",
        message: "This device is not paired with Baya. Scan a new pairing code.",
      });
      return;
    }

    this.attached.add(peer);
    this.options.onMessage(sender, message as ClientMessage);
  }

  private queueSend(peers: string[], message: ServerMessage): void {
    this.outbound = this.outbound
      .then(async () => {
        const relay = this.relay;
        if (!relay?.isOpen()) return;
        // Re-check on every delivery so a revoked owner cannot keep receiving
        // a stream after its pairing record is removed.
        const owners = await listPeers();
        const ct = Buffer.from(JSON.stringify(message)).toString("base64");
        for (const peer of peers) {
          if (!isPairedOwner(peer, owners)) {
            this.attached.delete(peer);
            continue;
          }
          try {
            relay.send(JSON.stringify({ peer, ct }));
          } catch {
            // A reconnect followed by session_sync recovers delivery.
          }
        }
      })
      .catch(() => {
        // A disconnected phone must not crash a running agent.
      });
  }
}
