import type { Ed25519Keypair } from "../pairing/crypto.ts";
import { getOrCreateEd25519Keypair, isPairedKey, listPeers } from "../pairing/storage.ts";
import type { ClientMessage, ServerMessage } from "../protocol/types.ts";
import { type DirectServer, directServer } from "./direct_server.ts";
import { deriveSessionKey, isSealed, open, ReplayGuard, seal } from "./e2e.ts";
import type { PeerChannel } from "./peer_channel.ts";
import type { RoomMeta } from "./relay_client.ts";
import { type RelayHub, type RoomLink, relayHub } from "./relay_hub.ts";

export interface OwnerHostOptions {
  roomId: string;
  roomMeta: RoomMeta;
  onMessage: (sender: PeerChannel, message: ClientMessage) => void;
  onFatal?: (error: Error) => void;
  /** Defaults to the process-wide hub. */
  hub?: RelayHub;
  /** Defaults to the process-wide direct endpoint. */
  direct?: DirectServer;
}

/**
 * One relay room owned by the standalone Baya host. Every frame is end-to-end
 * encrypted with the sender's key (see e2e.ts), so the relay can neither read
 * nor forge traffic. Pair requests from an unknown mobile key are admitted
 * only so the pairing service can validate the one-time token; every other
 * frame must come from a persisted owner.
 */
export class OwnerRelayHost {
  private link: RoomLink | null = null;
  private readonly attached = new Set<string>();
  private inbound: Promise<void> = Promise.resolve();
  private outbound: Promise<void> = Promise.resolve();
  private identity: Ed25519Keypair | null = null;
  private readonly keys = new Map<string, Buffer>();
  private readonly replay = new ReplayGuard();
  private readonly skewReportedAt = new Map<string, number>();
  private readonly hub: RelayHub;

  private readonly options: OwnerHostOptions;

  constructor(options: OwnerHostOptions) {
    this.options = options;
    this.hub = options.hub ?? relayHub();
  }

  /**
   * Joins the shared relay connection in the background. Relay availability
   * and the local agent host are independent: a sleeping laptop, VPN
   * transition, or relay outage must not make local sessions unusable.
   */
  start(): void {
    this.link?.close();
    const handlers = {
      onLine: (line: string) => {
        this.inbound = this.inbound
          .then(() => this.receive(line))
          .catch((error: unknown) => {
            process.stderr.write(
              `[baya] Ignored invalid mobile frame: ${
                error instanceof Error ? error.name : "error"
              }\n`,
            );
          });
      },
      ...(this.options.onFatal ? { onFatal: this.options.onFatal } : {}),
    };
    // Phones reach the room through the relay and, on a tailnet, directly;
    // every reply goes out both ways and arrives on whichever one they use.
    this.link = bothWays(
      this.hub.open(this.options.roomId, this.options.roomMeta, handlers),
      (this.options.direct ?? directServer()).open(
        this.options.roomId,
        this.options.roomMeta,
        handlers,
      ),
    );
  }

  stop(): void {
    this.link?.close();
    this.link = null;
    this.attached.clear();
  }

  broadcast(message: ServerMessage): void {
    this.queueSend([...this.attached], message);
  }

  sendTo(peer: string, message: ServerMessage): void {
    this.queueSend([peer], message);
  }

  updateMeta(meta: { model?: string; working?: boolean }): void {
    this.link?.updateMeta(meta);
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
    if (!isSealed(box)) return;
    this.identity ??= await getOrCreateEd25519Keypair();
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

  private queueSend(peers: string[], message: ServerMessage): void {
    this.outbound = this.outbound
      .then(async () => {
        const link = this.link;
        if (!link?.isOpen()) return;
        this.identity ??= await getOrCreateEd25519Keypair();
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
          link.send({ peer, ct });
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

/** One room reachable over the relay and directly. */
function bothWays(relay: RoomLink, direct: RoomLink): RoomLink {
  return {
    isOpen: () => relay.isOpen() || direct.isOpen(),
    send: (envelope) => {
      relay.send(envelope);
      direct.send(envelope);
    },
    updateMeta: (meta) => {
      relay.updateMeta(meta);
      direct.updateMeta(meta);
    },
    close: () => {
      relay.close();
      direct.close();
    },
  };
}
