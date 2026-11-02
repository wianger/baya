import { createPrivateKey, createPublicKey, getRandomValues, sign } from "node:crypto";

export interface Ed25519Keypair {
  publicKey: Uint8Array;
  /** The 32-byte Ed25519 seed (RFC 8032 private key). */
  secretKey: Uint8Array;
}

// DER prefix of a PKCS#8 Ed25519 private key; the 32-byte seed follows it.
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const ED25519_KEY_BYTES = 32;

function privateKey(seed: Uint8Array) {
  return createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  });
}

function publicKeyFor(seed: Uint8Array): Uint8Array {
  const jwk = createPublicKey(privateKey(seed)).export({ format: "jwk" });
  return Buffer.from(jwk.x!, "base64url");
}

/** Generates an Ed25519 keypair for relay challenge-response auth. */
export function generateEd25519Keypair(): Ed25519Keypair {
  const secretKey = getRandomValues(new Uint8Array(ED25519_KEY_BYTES));
  return { secretKey, publicKey: publicKeyFor(secretKey) };
}

export function ed25519Sign(seed: Uint8Array, message: Uint8Array): Uint8Array {
  return sign(null, message, privateKey(seed));
}

/**
 * Normalizes an Ed25519 public key written in standard or URL-safe base64,
 * padded or not, to standard padded base64 so keys compare by value.
 */
export function canonicalizeEd25519PublicKey(raw: string): string {
  if (typeof raw !== "string" || !/^[A-Za-z0-9+/_-]+={0,2}$/u.test(raw)) {
    throw new Error("Invalid Ed25519 public key encoding.");
  }
  const bytes = Buffer.from(raw.replace(/=+$/u, ""), "base64url");
  if (bytes.length !== ED25519_KEY_BYTES) {
    throw new Error("Ed25519 public keys are 32 bytes.");
  }
  return bytes.toString("base64");
}
