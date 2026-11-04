import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { type RawData, type WebSocket, WebSocketServer } from "ws";
import type { SessionHub } from "../acp/hub.ts";
import { PhoneConnection } from "../acp/phone.ts";
import type { Ed25519Keypair } from "../pairing/crypto.ts";
import { getOrCreateEd25519Keypair } from "../pairing/storage.ts";
import {
  type KeyPair,
  keyPairFromPrivate,
  MessageReader,
  NoiseError,
  Responder,
  sealData,
  sealMessage,
  x25519FromEd25519Seed,
  x25519PublicFromEd25519,
} from "./noise.ts";

/**
 * Where phones connect: WebSockets arriving through `tailscale serve` at
 * `…/baya-pair/<label>/direct`.
 *
 * Every frame is binary. The first two are a Noise IK handshake
 * (Noise_IK_25519_ChaChaPoly_SHA256, see noise.ts): the phone already knows
 * this computer's key from the pairing code, so one round trip authenticates
 * both sides with forward secrecy. The phone's first payload names its
 * Ed25519 identity, which must map to the static key it proved. After that,
 * every frame is a Noise transport message carrying (a piece of) one JSON-RPC
 * message, so nobody in between can read, forge, replay or reorder anything.
 */

/** Bytes a file stream may have waiting in the socket before it pauses. */
const SEND_BUFFER = 4 * 1024 * 1024;
export const PROLOGUE = Buffer.from("baya/1", "ascii");
const HANDSHAKE_TIMEOUT_MS = 10_000;
const PING_MS = 25_000;
/** Closed: the handshake or the transport failed. */
const CLOSE_NOISE = 4002;

export class DirectServer {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
  private readonly hub: SessionHub;
  private identity: Promise<{ ed25519: Ed25519Keypair; noise: KeyPair }> | null = null;

  constructor(hub: SessionHub) {
    this.hub = hub;
  }

  /** Accepts a WebSocket upgrade from one of the pairing listeners. */
  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    this.wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
  }

  private keys(): Promise<{ ed25519: Ed25519Keypair; noise: KeyPair }> {
    this.identity ??= getOrCreateEd25519Keypair().then((ed25519) => ({
      ed25519,
      noise: keyPairFromPrivate(x25519FromEd25519Seed(ed25519.secretKey)),
    }));
    return this.identity;
  }

  private accept(socket: WebSocket): void {
    const timer = setTimeout(() => socket.terminate(), HANDSHAKE_TIMEOUT_MS);
    // The phone waits for the reply before sending anything else, so one
    // listener is enough until the handshake is done.
    socket.once("message", (raw, isBinary) => {
      void this.keys().then(({ noise }) => {
        clearTimeout(timer);
        try {
          if (!isBinary) throw new NoiseError("Expected a handshake.");
          this.handshake(socket, noise, toBuffer(raw));
        } catch {
          socket.close(CLOSE_NOISE, "handshake");
        }
      });
    });
  }

  private handshake(socket: WebSocket, noise: KeyPair, hello: Buffer): void {
    const responder = new Responder({ prologue: PROLOGUE, staticKey: noise });
    const { payload, remoteStatic } = responder.readMessage(hello);
    const claim = JSON.parse(payload.toString("utf8")) as { ed25519?: unknown };
    const phoneKey = Buffer.from(String(claim.ed25519), "base64");
    if (phoneKey.length !== 32 || !x25519PublicFromEd25519(phoneKey).equals(remoteStatic)) {
      throw new NoiseError("The phone's identity does not match its key.");
    }
    const { message, session } = responder.writeMessage(Buffer.from("{}"));
    socket.send(message);

    const reader = new MessageReader();
    const phone = new PhoneConnection({
      key: phoneKey.toString("base64"),
      hub: this.hub,
      send: (json) => {
        if (socket.readyState !== socket.OPEN) return;
        for (const frame of sealMessage(session.send, Buffer.from(JSON.stringify(json)))) {
          socket.send(frame);
        }
      },
      close: (code, reason) => socket.close(code, reason),
      sendData: async (stream, offset, bytes) => {
        // Let the socket drain rather than buffer a whole file.
        while (socket.readyState === socket.OPEN && socket.bufferedAmount > SEND_BUFFER) {
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
        if (socket.readyState !== socket.OPEN) throw new Error("The phone disconnected.");
        socket.send(sealData(session.send, stream, offset, bytes));
      },
    });
    const ping = setInterval(() => socket.ping(), PING_MS);
    socket.on("message", (raw, isBinary) => {
      try {
        if (!isBinary) throw new NoiseError("Expected a binary frame.");
        const message = reader.read(session.receive, toBuffer(raw));
        if (message === null) return;
        if (Buffer.isBuffer(message)) phone.receive(JSON.parse(message.toString("utf8")));
        else phone.receiveData(message);
      } catch (error) {
        if (!(error instanceof NoiseError) && !(error instanceof SyntaxError)) throw error;
        // A failed frame leaves the counters out of step: the stream is over.
        socket.close(CLOSE_NOISE, "transport");
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
