import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import { getOrCreateEd25519Keypair, isPairedKey, listPeers } from "../pairing/storage.js";
import { resolveRelayUrl, toWebSocketUrl } from "../config.js";
import { deriveSessionKey, isSealed, open, ReplayGuard, seal } from "./e2e.js";
import { RelayClient, type RoomMeta } from "./relay_client.js";
import type { PeerChannel } from "./peer_channel.js";

export interface OwnerHostOptions {
  roomId: string;
  roomMeta: RoomMeta;
  onMessage: (sender: PeerChannel, message: ClientMessage) => void;
  onFatal?: (error: Error) => void;
}

/**
 * One relay room owned by the standalone Baya host. Every frame is end-to-end
 * encrypted with the sender's key (see e2e.ts), so the relay can neither read
 * nor forge traffic. Pair requests from an unknown mobile key are admitted
 * only so the pairing service can validate the one-time token; every other
 * frame must come from a persisted owner.
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
  private identity: Ed25519Keypair | null = null;
  private readonly keys = new Map<string, Buffer>();
  private readonly replay = new ReplayGuard();
  private readonly skewReportedAt = new Map<string, number>();

  constructor(private readonly options: OwnerHostOptions) {
    this.meta = { ...options.roomMeta };
  }

  /**
   * Starts connecting in the background. Relay availability and the local
   * agent host are independent: a sleeping laptop, VPN transition, or relay
   * outage must not make local sessions unusable.
   */
  start(): void {
    this.stopped = false;
    void this.connect().catch((error: unknown) => {
      this.options.onFatal?.(
        error instanceof Error ? error : new Error("Initial relay connection failed."),
      );
      this.scheduleReconnect();
    });
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
    this.identity = identity;
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

    const peer = outer["peer"];
    const box = Buffer.from(outer["ct"], "base64");
    if (!isSealed(box)) {
      // A pre-encryption app. Error frames carry nothing secret, so this one
      // goes out in the clear so the old app can show it.
      this.sendPlain(peer, {
        type: "error",
        code: "upgrade_required",
        message: "Update the Baya app: this computer requires end-to-end encryption.",
      });
      return;
    }
    const key = this.keyFor(peer);
    if (!key) return;
    let message: unknown;
    try {
      const opened = open(key, "p2h", this.options.roomId, box);
      const verdict = this.replay.check(opened);
      if (verdict === "stale") this.reportClockSkew(peer, opened.sentAt);
      if (verdict !== "ok") return;
      message = JSON.parse(opened.plaintext.toString("utf8"));
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

    const sender: PeerChannel = {
      remotePeerId: peer,
      send: (reply) => this.queueSend([peer], reply),
    };

    if ((message as { type: string }).type === "pair_request") {
      this.options.onMessage(sender, message as ClientMessage);
      return;
    }

    if (!isPairedKey(peer, await listPeers())) {
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

  private keyFor(peer: string): Buffer | null {
    const cached = this.keys.get(peer);
    if (cached) return cached;
    if (!this.identity) return null;
    try {
      const key = deriveSessionKey(
        this.identity.secretKey,
        this.identity.publicKey,
        Buffer.from(peer, "base64"),
      );
      this.keys.set(peer, key);
      return key;
    } catch {
      return null;
    }
  }

  /** An authentic but out-of-window frame almost always means a wrong clock. */
  private reportClockSkew(peer: string, sentAt: number): void {
    const now = Date.now();
    if (now - (this.skewReportedAt.get(peer) ?? 0) < 60_000) return;
    this.skewReportedAt.set(peer, now);
    const minutes = Math.round(Math.abs(now - sentAt) / 60_000);
    this.sendTo(peer, {
      type: "error",
      code: "clock_skew",
      message: `This phone's clock is ${minutes} min off from the computer. Turn on automatic date & time.`,
    });
  }

  private sendPlain(peer: string, message: ServerMessage): void {
    const ct = Buffer.from(JSON.stringify(message)).toString("base64");
    try {
      this.relay?.send(JSON.stringify({ peer, ct }));
    } catch {
      // best effort
    }
  }

  private queueSend(peers: string[], message: ServerMessage): void {
    this.outbound = this.outbound
      .then(async () => {
        const relay = this.relay;
        if (!relay?.isOpen()) return;
        // Re-check on every delivery so a revoked owner cannot keep receiving
        // a stream after its pairing record is removed.
        const owners = await listPeers();
        const plaintext = Buffer.from(JSON.stringify(message));
        for (const peer of peers) {
          if (!isPairedKey(peer, owners) && !isForUnpairedPeer(message)) {
            this.attached.delete(peer);
            continue;
          }
          const key = this.keyFor(peer);
          if (!key) continue;
          const ct = seal(key, "h2p", this.options.roomId, plaintext).toString("base64");
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

/** Replies that must reach a key that is not (or no longer) an owner. */
function isForUnpairedPeer(message: ServerMessage): boolean {
  return (
    message.type === "pair_ok" ||
    message.type === "pair_error" ||
    (message.type === "error" && message.code === "unknown_peer")
  );
}
