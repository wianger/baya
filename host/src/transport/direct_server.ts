import { createPublicKey, randomBytes, verify } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { type RawData, type WebSocket, WebSocketServer } from "ws";
import type { SessionHub } from "../acp/hub.ts";
import { PhoneConnection } from "../acp/phone.ts";
import type { Ed25519Keypair } from "../pairing/crypto.ts";
import { getOrCreateEd25519Keypair } from "../pairing/storage.ts";
import { deriveSessionKey, E2EError, open, ReplayGuard, seal } from "./e2e.ts";

/**
 * Where phones connect: WebSockets arriving through `tailscale serve` at
 * `…/baya-pair/<label>/direct`.
 *
 * A phone proves its Ed25519 key (hello/challenge/auth as JSON text), then
 * every frame is binary: one sealed JSON-RPC message (see e2e.ts). The
 * phone's key is the one it proved, so nobody in between can read, forge or
 * redirect a frame.
 */

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HELLO_TIMEOUT_MS = 5_000;
const PING_MS = 25_000;
const CLOSE_CLOCK_SKEW = 4001;

export class DirectServer {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024 });
  private readonly hub: SessionHub;
  private identity: Promise<Ed25519Keypair> | null = null;

  constructor(hub: SessionHub) {
    this.hub = hub;
  }

  /** Accepts a WebSocket upgrade from one of the pairing listeners. */
  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    this.wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
  }

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
      // Load the identity first so frames right after `auth` find a listener.
      this.identity ??= getOrCreateEd25519Keypair();
      void this.identity.then((identity) => this.challenge(socket, key, identity, timer));
    });
  }

  private challenge(
    socket: WebSocket,
    key: Buffer,
    identity: Ed25519Keypair,
    timer: NodeJS.Timeout,
  ): void {
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
      this.register(socket, key, identity);
    });
  }

  private register(socket: WebSocket, phoneKey: Buffer, identity: Ed25519Keypair): void {
    const key = deriveSessionKey(identity.secretKey, identity.publicKey, phoneKey);
    const replay = new ReplayGuard();
    const phone = new PhoneConnection({
      key: phoneKey.toString("base64"),
      hub: this.hub,
      send: (message) => {
        if (socket.readyState !== socket.OPEN) return;
        socket.send(seal(key, "h2p", Buffer.from(JSON.stringify(message))));
      },
      close: (code, reason) => socket.close(code, reason),
    });
    const ping = setInterval(() => socket.ping(), PING_MS);
    socket.on("message", (raw, isBinary) => {
      if (!isBinary) return;
      try {
        const opened = open(key, "p2h", toBuffer(raw));
        const verdict = replay.check(opened);
        if (verdict === "stale") {
          const minutes = Math.round(Math.abs(Date.now() - opened.sentAt) / 60_000);
          socket.close(CLOSE_CLOCK_SKEW, `clock_skew:${minutes}`);
          return;
        }
        if (verdict !== "ok") return;
        phone.receive(JSON.parse(opened.plaintext.toString("utf8")));
      } catch (error) {
        if (!(error instanceof E2EError) && !(error instanceof SyntaxError)) throw error;
        // Forged, corrupted or not JSON: drop it.
      }
    });
    socket.on("close", () => {
      clearInterval(ping);
      phone.closed();
    });
  }
}

function toBuffer(raw: RawData): Buffer {
  if (Buffer.isBuffer(raw)) return raw;
  if (Array.isArray(raw)) return Buffer.concat(raw);
  return Buffer.from(raw);
}
