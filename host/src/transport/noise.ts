import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  randomBytes,
} from "node:crypto";

/**
 * The Noise Protocol Framework (revision 34), the one pattern Baya uses:
 *
 *   Noise_IK_25519_ChaChaPoly_SHA256
 *     <- s
 *     ...
 *     -> e, es, s, ss
 *     <- e, ee, se
 *
 * The phone knows the computer's static key from the pairing code, so one
 * round trip authenticates both sides, and the ephemeral keys give forward
 * secrecy: a stolen identity key cannot decrypt recorded traffic.
 *
 * Pinned to the cacophony test vectors in test/noise.test.ts.
 */

export const PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256";
const DH_LEN = 32;
const TAG_LEN = 16;
/** The largest Noise message, ciphertext and tag included. */
export const MAX_MESSAGE = 65_535;

const PKCS8_X25519 = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519 = Buffer.from("302a300506032b656e032100", "hex");

export class NoiseError extends Error {
  override readonly name = "NoiseError";
}

export interface KeyPair {
  publicKey: Buffer;
  privateKey: Buffer;
}

export function keyPairFromPrivate(privateKey: Uint8Array): KeyPair {
  const key = createPrivateKey({
    key: Buffer.concat([PKCS8_X25519, privateKey]),
    format: "der",
    type: "pkcs8",
  });
  const publicKey = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x!, "base64url");
  return { publicKey, privateKey: Buffer.from(privateKey) };
}

export function generateKeyPair(): KeyPair {
  return keyPairFromPrivate(randomBytes(DH_LEN));
}

function dh(own: KeyPair, remotePublic: Uint8Array): Buffer {
  const shared = diffieHellman({
    privateKey: createPrivateKey({
      key: Buffer.concat([PKCS8_X25519, own.privateKey]),
      format: "der",
      type: "pkcs8",
    }),
    publicKey: createPublicKey({
      key: Buffer.concat([SPKI_X25519, remotePublic]),
      format: "der",
      type: "spki",
    }),
  });
  if (shared.every((byte) => byte === 0)) throw new NoiseError("Invalid public key.");
  return shared;
}

const hash = (...parts: Uint8Array[]): Buffer => {
  const h = createHash("sha256");
  for (const part of parts) h.update(part);
  return h.digest();
};

const hmac = (key: Uint8Array, ...parts: Uint8Array[]): Buffer => {
  const h = createHmac("sha256", key);
  for (const part of parts) h.update(part);
  return h.digest();
};

function hkdf(chainingKey: Uint8Array, input: Uint8Array): [Buffer, Buffer] {
  const temp = hmac(chainingKey, input);
  const first = hmac(temp, Buffer.from([1]));
  const second = hmac(temp, first, Buffer.from([2]));
  return [first, second];
}

/** One direction of transport: a key and a 64-bit message counter. */
export class CipherState {
  private key: Buffer | null = null;
  private nonce = 0n;

  initialize(key: Buffer | null): void {
    this.key = key;
    this.nonce = 0n;
  }

  get hasKey(): boolean {
    return this.key !== null;
  }

  private iv(): Buffer {
    if (this.nonce >= 0xffff_ffff_ffff_ffffn) throw new NoiseError("Nonce exhausted.");
    const iv = Buffer.alloc(12);
    iv.writeBigUInt64LE(this.nonce, 4);
    return iv;
  }

  encrypt(ad: Uint8Array, plaintext: Uint8Array): Buffer {
    if (!this.key) return Buffer.from(plaintext);
    const cipher = createCipheriv("chacha20-poly1305", this.key, this.iv(), {
      authTagLength: TAG_LEN,
    });
    cipher.setAAD(ad, { plaintextLength: plaintext.length });
    const out = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
    this.nonce++;
    return out;
  }

  decrypt(ad: Uint8Array, ciphertext: Uint8Array): Buffer {
    if (!this.key) return Buffer.from(ciphertext);
    if (ciphertext.length < TAG_LEN) throw new NoiseError("Message too short.");
    const body = ciphertext.subarray(0, ciphertext.length - TAG_LEN);
    const decipher = createDecipheriv("chacha20-poly1305", this.key, this.iv(), {
      authTagLength: TAG_LEN,
    });
    decipher.setAAD(ad, { plaintextLength: body.length });
    decipher.setAuthTag(ciphertext.subarray(ciphertext.length - TAG_LEN));
    let out: Buffer;
    try {
      out = Buffer.concat([decipher.update(body), decipher.final()]);
    } catch {
      throw new NoiseError("Message failed authentication.");
    }
    this.nonce++;
    return out;
  }
}

class SymmetricState {
  private chainingKey: Buffer;
  hash: Buffer;
  private readonly cipher = new CipherState();

  constructor(protocolName: string) {
    const name = Buffer.from(protocolName, "ascii");
    this.hash =
      name.length <= 32 ? Buffer.concat([name, Buffer.alloc(32 - name.length)]) : hash(name);
    this.chainingKey = this.hash;
  }

  mixKey(input: Uint8Array): void {
    const [chainingKey, key] = hkdf(this.chainingKey, input);
    this.chainingKey = chainingKey;
    this.cipher.initialize(key);
  }

  mixHash(data: Uint8Array): void {
    this.hash = hash(this.hash, data);
  }

  encryptAndHash(plaintext: Uint8Array): Buffer {
    const ciphertext = this.cipher.encrypt(this.hash, plaintext);
    this.mixHash(ciphertext);
    return ciphertext;
  }

  decryptAndHash(ciphertext: Uint8Array): Buffer {
    const plaintext = this.cipher.decrypt(this.hash, ciphertext);
    this.mixHash(ciphertext);
    return plaintext;
  }

  split(): [CipherState, CipherState] {
    const [first, second] = hkdf(this.chainingKey, Buffer.alloc(0));
    const a = new CipherState();
    const b = new CipherState();
    a.initialize(first);
    b.initialize(second);
    return [a, b];
  }

  get keyed(): boolean {
    return this.cipher.hasKey;
  }
}

export interface Session {
  send: CipherState;
  receive: CipherState;
  /** Binds the session: equal on both sides, unique per handshake. */
  handshakeHash: Buffer;
  /** The other side's static public key. */
  remoteStatic: Buffer;
}

/** The phone's side: knows the computer's static key up front. */
export class Initiator {
  private readonly state = new SymmetricState(PROTOCOL_NAME);
  private readonly s: KeyPair;
  private readonly rs: Buffer;
  private readonly e: KeyPair;

  constructor(options: {
    prologue: Uint8Array;
    staticKey: KeyPair;
    remoteStatic: Uint8Array;
    ephemeral?: KeyPair;
  }) {
    this.s = options.staticKey;
    this.rs = Buffer.from(options.remoteStatic);
    this.e = options.ephemeral ?? generateKeyPair();
    this.state.mixHash(options.prologue);
    this.state.mixHash(this.rs);
  }

  /** -> e, es, s, ss */
  writeMessage(payload: Uint8Array): Buffer {
    this.state.mixHash(this.e.publicKey);
    this.state.mixKey(dh(this.e, this.rs));
    const encryptedStatic = this.state.encryptAndHash(this.s.publicKey);
    this.state.mixKey(dh(this.s, this.rs));
    return Buffer.concat([this.e.publicKey, encryptedStatic, this.state.encryptAndHash(payload)]);
  }

  /** <- e, ee, se */
  readMessage(message: Uint8Array): { payload: Buffer; session: Session } {
    if (message.length < DH_LEN + TAG_LEN) throw new NoiseError("Handshake reply too short.");
    const re = Buffer.from(message.subarray(0, DH_LEN));
    this.state.mixHash(re);
    this.state.mixKey(dh(this.e, re));
    this.state.mixKey(dh(this.s, re));
    const payload = this.state.decryptAndHash(message.subarray(DH_LEN));
    const [send, receive] = this.state.split();
    return {
      payload,
      session: { send, receive, handshakeHash: this.state.hash, remoteStatic: this.rs },
    };
  }
}

/** The computer's side. */
export class Responder {
  private readonly state = new SymmetricState(PROTOCOL_NAME);
  private readonly s: KeyPair;
  private readonly e: KeyPair;
  private re: Buffer | null = null;
  private rs: Buffer | null = null;

  constructor(options: { prologue: Uint8Array; staticKey: KeyPair; ephemeral?: KeyPair }) {
    this.s = options.staticKey;
    this.e = options.ephemeral ?? generateKeyPair();
    this.state.mixHash(options.prologue);
    this.state.mixHash(this.s.publicKey);
  }

  /** -> e, es, s, ss. Returns the payload and the initiator's static key. */
  readMessage(message: Uint8Array): { payload: Buffer; remoteStatic: Buffer } {
    const minimum = DH_LEN + DH_LEN + TAG_LEN + TAG_LEN;
    if (message.length < minimum) throw new NoiseError("Handshake too short.");
    const re = Buffer.from(message.subarray(0, DH_LEN));
    this.re = re;
    this.state.mixHash(re);
    this.state.mixKey(dh(this.s, re));
    const rs = this.state.decryptAndHash(message.subarray(DH_LEN, DH_LEN * 2 + TAG_LEN));
    this.rs = rs;
    this.state.mixKey(dh(this.s, rs));
    const payload = this.state.decryptAndHash(message.subarray(DH_LEN * 2 + TAG_LEN));
    return { payload, remoteStatic: rs };
  }

  /** <- e, ee, se */
  writeMessage(payload: Uint8Array): { message: Buffer; session: Session } {
    if (!this.re || !this.rs) throw new NoiseError("Read the first message first.");
    this.state.mixHash(this.e.publicKey);
    this.state.mixKey(dh(this.e, this.re));
    this.state.mixKey(dh(this.e, this.rs));
    const message = Buffer.concat([this.e.publicKey, this.state.encryptAndHash(payload)]);
    const [receive, send] = this.state.split();
    return {
      message,
      session: { send, receive, handshakeHash: this.state.hash, remoteStatic: this.rs },
    };
  }
}

/**
 * Transport framing over Noise: a JSON-RPC message may exceed one Noise
 * message (64 KiB), so each WebSocket frame carries one Noise message whose
 * plaintext is a flag byte (1 = last piece) and a piece of the message.
 */
export const MAX_PIECE = MAX_MESSAGE - TAG_LEN - 1;

export function sealMessage(cipher: CipherState, plaintext: Uint8Array): Buffer[] {
  const frames: Buffer[] = [];
  let offset = 0;
  do {
    const piece = plaintext.subarray(offset, offset + MAX_PIECE);
    offset += piece.length;
    const last = offset >= plaintext.length;
    frames.push(
      cipher.encrypt(Buffer.alloc(0), Buffer.concat([Buffer.from([last ? 1 : 0]), piece])),
    );
  } while (offset < plaintext.length);
  return frames;
}

/** Reassembles pieces; returns a whole message once its last piece arrives. */
export class MessageReader {
  private pieces: Buffer[] = [];
  private size = 0;
  private readonly limit: number;

  constructor(limit = 32 * 1024 * 1024) {
    this.limit = limit;
  }

  read(cipher: CipherState, frame: Uint8Array): Buffer | null {
    const plaintext = cipher.decrypt(Buffer.alloc(0), frame);
    if (plaintext.length < 1 || plaintext[0]! > 1) throw new NoiseError("Bad frame.");
    this.size += plaintext.length - 1;
    if (this.size > this.limit) throw new NoiseError("Message too large.");
    this.pieces.push(plaintext.subarray(1));
    if (plaintext[0] !== 1) return null;
    const message = Buffer.concat(this.pieces);
    this.pieces = [];
    this.size = 0;
    return message;
  }
}

/** X25519 private scalar of an Ed25519 seed (RFC 8032 §5.1.5). */
export function x25519FromEd25519Seed(seed: Uint8Array): Buffer {
  return createHash("sha512").update(seed).digest().subarray(0, 32);
}

const P = 2n ** 255n - 19n;

/** Birational map from an Ed25519 public key to its X25519 u-coordinate. */
export function x25519PublicFromEd25519(publicKey: Uint8Array): Buffer {
  if (publicKey.length !== 32) throw new NoiseError("Ed25519 public keys are 32 bytes.");
  const bytes = Buffer.from(publicKey);
  bytes[31]! &= 0x7f;
  const y = littleEndianToBigInt(bytes);
  if (y >= P) throw new NoiseError("Invalid Ed25519 public key.");
  const u = mod((1n + y) * modInverse(mod(1n - y)));
  return bigIntToLittleEndian(u);
}

function mod(value: bigint): bigint {
  const result = value % P;
  return result >= 0n ? result : result + P;
}

function modInverse(value: bigint): bigint {
  if (value === 0n) throw new NoiseError("Invalid Ed25519 public key.");
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
