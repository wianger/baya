// Regenerates .orchestration/contracts/e2e_v2.json: `node test/make-e2e-vector.ts`.
import { writeFileSync } from "node:fs";
import { generateEd25519Keypair } from "../src/pairing/crypto.ts";
import { deriveSessionKey, seal, x25519PublicFromEd25519 } from "../src/transport/e2e.ts";

void generateEd25519Keypair;
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const { createPrivateKey, createPublicKey } = await import("node:crypto");
const publicFor = (seed: Buffer) =>
  Buffer.from(
    createPublicKey(
      createPrivateKey({
        key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]),
        format: "der",
        type: "pkcs8",
      }),
    ).export({ format: "jwk" }).x!,
    "base64url",
  );

const phoneSeed = Buffer.alloc(32, 1);
const hostSeed = Buffer.alloc(32, 2);
const phonePk = publicFor(phoneSeed);
const hostPk = publicFor(hostSeed);
const key = deriveSessionKey(phoneSeed, phonePk, hostPk);
const ts = 1790000000000;
const p2h = '{"jsonrpc":"2.0","id":1,"method":"session/list","params":{}}';
const h2p = '{"jsonrpc":"2.0","id":1,"result":{"sessions":[]}}';
const p2hNonce = Buffer.alloc(12, 7);
const h2pNonce = Buffer.alloc(12, 9);
const vector = {
  phone_seed: b64(phoneSeed),
  phone_pk: b64(phonePk),
  phone_x25519_pk: b64(x25519PublicFromEd25519(phonePk)),
  host_seed: b64(hostSeed),
  host_pk: b64(hostPk),
  session_key: b64(key),
  ts,
  p2h: {
    plaintext: p2h,
    nonce: b64(p2hNonce),
    box: b64(seal(key, "p2h", Buffer.from(p2h), ts, p2hNonce)),
  },
  h2p: {
    plaintext: h2p,
    nonce: b64(h2pNonce),
    box: b64(seal(key, "h2p", Buffer.from(h2p), ts, h2pNonce)),
  },
};
writeFileSync(
  new URL("../../.orchestration/contracts/e2e_v2.json", import.meta.url),
  `${JSON.stringify(vector, null, 2)}\n`,
);
