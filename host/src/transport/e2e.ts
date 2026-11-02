import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
  randomBytes,
} from "node:crypto";

/**
 * End-to-end encryption between a paired phone and this host.
 *
 * Both sides already hold long-term Ed25519 keys and learn each other's public
 * key out of band (the pairing QR carries the host key; the host stores the
 * phone key). Each side converts its Ed25519 key to X25519, and the static
 * Diffie-Hellman result keys ChaCha20-Poly1305. Anything in between
 * (`tailscale serve`, a proxy) sees only ciphertext and cannot forge a frame
 * because it cannot compute the key.
 *
 *   key   = HKDF-SHA256(X25519(self, peer), salt = "baya-e2e-v1",
 *                       info = min(edA, edB) || max(edA, edB))
 *   box   = 0xBE 0x01 || nonce(12) || ChaCha20-Poly1305(ts_ms(8) || json)
 *   aad   = "baya-e2e-v1|" + ("p2h" | "h2p") + "|" + host room id
 *
 * The direction and room in the AAD stop anyone in between from reflecting a frame
 * back to its sender or moving it to another session. The timestamp plus a
 * nonce cache bound replays to a short window.
 */

export const E2E_MAGIC = Buffer.from([0xbe, 0x01]);
export const REPLAY_WINDOW_MS = 5 * 60_000;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const LABEL = "baya-e2e-v1";
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const P = 2n ** 255n - 19n;

export type Direction = "p2h" | "h2p";

export class E2EError extends Error {
  override readonly name = "E2EError";
}

/** X25519 private scalar for an Ed25519 seed (RFC 8032 §5.1.5 / RFC 7748). */
export function x25519PrivateFromEd25519Seed(seed: Uint8Array): Buffer {
  return createHash("sha512").update(seed).digest().subarray(0, 32);
}

/** Birational map from an Ed25519 public key to its X25519 u-coordinate. */
export function x25519PublicFromEd25519(publicKey: Uint8Array): Buffer {
  if (publicKey.length !== 32) throw new E2EError("Ed25519 public keys are 32 bytes.");
  const bytes = Buffer.from(publicKey);
  bytes[31]! &= 0x7f;
  const y = littleEndianToBigInt(bytes);
  if (y >= P) throw new E2EError("Invalid Ed25519 public key.");
  const u = mod((1n + y) * modInverse(mod(1n - y)));
  return bigIntToLittleEndian(u);
}

/** Shared ChaCha20-Poly1305 key for one (self, peer) pair. */
export function deriveSessionKey(
  selfSeed: Uint8Array,
  selfPublic: Uint8Array,
  peerPublic: Uint8Array,
): Buffer {
  const privateKey = createPrivateKey({
    key: Buffer.concat([PKCS8_X25519_PREFIX, x25519PrivateFromEd25519Seed(selfSeed)]),
    format: "der",
    type: "pkcs8",
  });
  const publicKey = createPublicKey({
    key: Buffer.concat([SPKI_X25519_PREFIX, x25519PublicFromEd25519(peerPublic)]),
    format: "der",
    type: "spki",
  });
  const shared = diffieHellman({ privateKey, publicKey });
  if (shared.every((byte) => byte === 0)) throw new E2EError("Degenerate peer key.");
  const [low, high] =
    Buffer.compare(Buffer.from(selfPublic), Buffer.from(peerPublic)) <= 0
      ? [selfPublic, peerPublic]
      : [peerPublic, selfPublic];
  return Buffer.from(hkdfSync("sha256", shared, LABEL, Buffer.concat([low, high]), 32));
}

export function seal(
  key: Uint8Array,
  direction: Direction,
  room: string,
  plaintext: Uint8Array,
  now = Date.now(),
  nonce: Uint8Array = randomBytes(NONCE_BYTES),
): Buffer {
  const body = Buffer.alloc(8 + plaintext.length);
  body.writeBigUInt64BE(BigInt(now), 0);
  Buffer.from(plaintext).copy(body, 8);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: TAG_BYTES });
  cipher.setAAD(aad(direction, room), { plaintextLength: body.length });
  const ciphertext = Buffer.concat([cipher.update(body), cipher.final()]);
  return Buffer.concat([E2E_MAGIC, nonce, ciphertext, cipher.getAuthTag()]);
}

export interface Opened {
  plaintext: Buffer;
  sentAt: number;
  nonce: string;
}

export function open(key: Uint8Array, direction: Direction, room: string, box: Uint8Array): Opened {
  const data = Buffer.from(box);
  if (!isSealed(data) || data.length < E2E_MAGIC.length + NONCE_BYTES + 8 + TAG_BYTES) {
    throw new E2EError("Not an encrypted Baya frame.");
  }
  const nonce = data.subarray(2, 2 + NONCE_BYTES);
  const tag = data.subarray(data.length - TAG_BYTES);
  const ciphertext = data.subarray(2 + NONCE_BYTES, data.length - TAG_BYTES);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: TAG_BYTES });
  decipher.setAAD(aad(direction, room), { plaintextLength: ciphertext.length });
  decipher.setAuthTag(tag);
  let body: Buffer;
  try {
    body = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  } catch {
    throw new E2EError("Frame failed authentication.");
  }
  return {
    sentAt: Number(body.readBigUInt64BE(0)),
    plaintext: body.subarray(8),
    nonce: nonce.toString("base64"),
  };
}

export function isSealed(data: Uint8Array): boolean {
  return data.length >= 2 && data[0] === E2E_MAGIC[0] && data[1] === E2E_MAGIC[1];
}

/** Rejects frames outside the replay window and nonces already seen in it. */
export class ReplayGuard {
  private readonly seen = new Map<string, number>();
  private readonly windowMs: number;

  constructor(windowMs = REPLAY_WINDOW_MS) {
    this.windowMs = windowMs;
  }

  check(opened: Opened, now = Date.now()): "ok" | "stale" | "replayed" {
    if (Math.abs(now - opened.sentAt) > this.windowMs) return "stale";
    for (const [nonce, at] of this.seen) {
      if (now - at <= this.windowMs * 2) break;
      this.seen.delete(nonce);
    }
    if (this.seen.has(opened.nonce)) return "replayed";
    this.seen.set(opened.nonce, now);
    return "ok";
  }
}

function aad(direction: Direction, room: string): Buffer {
  return Buffer.from(`${LABEL}|${direction}|${room}`, "utf8");
}

function mod(value: bigint): bigint {
  const result = value % P;
  return result >= 0n ? result : result + P;
}

function modInverse(value: bigint): bigint {
  if (value === 0n) throw new E2EError("Invalid Ed25519 public key.");
  let result = 1n;
  let base = value;
  let exponent = P - 2n;
  while (exponent > 0n) {
    if (exponent & 1n) result = (result * base) % P;
    base = (base * base) % P;
    exponent >>= 1n;
  }
  return result;
}

function littleEndianToBigInt(bytes: Buffer): bigint {
  let value = 0n;
  for (let index = bytes.length - 1; index >= 0; index--)
    value = (value << 8n) | BigInt(bytes[index]!);
  return value;
}

function bigIntToLittleEndian(value: bigint): Buffer {
  const out = Buffer.alloc(32);
  let rest = value;
  for (let index = 0; index < 32; index++) {
    out[index] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  return out;
}
