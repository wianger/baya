import { createPrivateKey, createPublicKey } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";
import { generateEd25519Keypair } from "../src/pairing/crypto.ts";
import {
  deriveSessionKey,
  open,
  ReplayGuard,
  seal,
  x25519PrivateFromEd25519Seed,
  x25519PublicFromEd25519,
} from "../src/transport/e2e.ts";

const fixture = JSON.parse(
  readFileSync(new URL("../../.orchestration/contracts/e2e_v2.json", import.meta.url), "utf8"),
) as {
  phone_seed: string;
  phone_pk: string;
  host_seed: string;
  host_pk: string;
  session_key: string;
  ts: number;
  p2h: { plaintext: string; box: string };
  h2p: { plaintext: string; box: string };
};
const b64 = (value: string) => Buffer.from(value, "base64");

describe("Ed25519 → X25519", () => {
  test("the public-key map matches the key derived from the converted seed", () => {
    for (let index = 0; index < 8; index++) {
      const keypair = generateEd25519Keypair();
      const viaSeed = createPublicKey(
        createPrivateKey({
          key: Buffer.concat([
            Buffer.from("302e020100300506032b656e04220420", "hex"),
            x25519PrivateFromEd25519Seed(keypair.secretKey),
          ]),
          format: "der",
          type: "pkcs8",
        }),
      ).export({ format: "jwk" }).x!;
      expect(x25519PublicFromEd25519(keypair.publicKey).toString("base64url")).toBe(viaSeed);
    }
  });

  test("both sides derive the same session key", () => {
    const phone = generateEd25519Keypair();
    const host = generateEd25519Keypair();
    expect(deriveSessionKey(phone.secretKey, phone.publicKey, host.publicKey)).toEqual(
      deriveSessionKey(host.secretKey, host.publicKey, phone.publicKey),
    );
  });
});

describe("sealed frames", () => {
  const key = b64(fixture.session_key);

  test("matches the shared cross-language fixture", () => {
    expect(
      deriveSessionKey(b64(fixture.host_seed), b64(fixture.host_pk), b64(fixture.phone_pk)),
    ).toEqual(key);
    expect(
      deriveSessionKey(b64(fixture.phone_seed), b64(fixture.phone_pk), b64(fixture.host_pk)),
    ).toEqual(key);
    const p2h = open(key, "p2h", b64(fixture.p2h.box));
    expect(p2h.plaintext.toString()).toBe(fixture.p2h.plaintext);
    expect(p2h.sentAt).toBe(fixture.ts);
    const h2p = seal(
      key,
      "h2p",
      Buffer.from(fixture.h2p.plaintext),
      fixture.ts,
      b64(fixture.h2p.box).subarray(2, 14),
    );
    expect(h2p.toString("base64")).toBe(fixture.h2p.box);
  });

  test("direction and tampering are authenticated", () => {
    const box = b64(fixture.p2h.box);
    expect(() => open(key, "h2p", box)).toThrow(/authentication/);
    const tampered = Buffer.from(box);
    tampered[20]! ^= 1;
    expect(() => open(key, "p2h", tampered)).toThrow(/authentication/);
    expect(() => open(Buffer.alloc(32), "p2h", box)).toThrow(/authentication/);
    expect(() => open(key, "p2h", Buffer.from('{"type":"ping"}'))).toThrow(/Not an encrypted/);
  });

  test("the replay guard rejects stale and repeated frames", () => {
    const guard = new ReplayGuard(1_000);
    const opened = open(key, "p2h", b64(fixture.p2h.box));
    expect(guard.check(opened, fixture.ts + 2_000)).toBe("stale");
    expect(guard.check(opened, fixture.ts + 10)).toBe("ok");
    expect(guard.check(opened, fixture.ts + 20)).toBe("replayed");
  });
});
