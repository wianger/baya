import { createPublicKey, verify } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";

const homes: string[] = [];

function isolatedHome(): string {
  const home = mkdtempSync(join(tmpdir(), "baya-storage-"));
  homes.push(home);
  process.env["BAYA_HOME"] = home;
  process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
  vi.resetModules();
  return home;
}

afterEach(() => {
  delete process.env["BAYA_HOME"];
  delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
  vi.resetModules();
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

const PHONE_A = Buffer.alloc(32, 1);
const PHONE_B = Buffer.alloc(32, 2);

describe("Ed25519 helpers", () => {
  test("sign with node:crypto and verify against the derived public key", async () => {
    const { ed25519Sign, generateEd25519Keypair } = await import("../src/pairing/crypto.js");
    const keypair = generateEd25519Keypair();
    const message = Buffer.from("challenge");
    const signature = ed25519Sign(keypair.secretKey, message);
    const publicKey = createPublicKey({
      key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(keypair.publicKey).toString("base64url") },
      format: "jwk",
    });
    expect(signature).toHaveLength(64);
    expect(verify(null, message, publicKey, signature)).toBe(true);
  });

  test("canonicalizes standard and URL-safe spellings to one key", async () => {
    const { canonicalizeEd25519PublicKey } = await import("../src/pairing/crypto.js");
    const key = Buffer.from(Array.from({ length: 32 }, (_, index) => index * 7 + 250));
    const standard = key.toString("base64");
    expect(canonicalizeEd25519PublicKey(key.toString("base64url"))).toBe(standard);
    expect(canonicalizeEd25519PublicKey(standard.replace(/=+$/u, ""))).toBe(standard);
    expect(() => canonicalizeEd25519PublicKey("short")).toThrow();
    expect(() => canonicalizeEd25519PublicKey("not base64!")).toThrow();
  });
});

describe("host identity", () => {
  test("a forced file identity is created once and reused", async () => {
    const home = isolatedHome();
    const storage = await import("../src/pairing/storage.js");
    const first = await storage.getOrCreateEd25519Keypair();
    const file = join(home, "identity.json");
    expect(existsSync(file)).toBe(true);
    if (process.platform !== "win32") expect(statSync(file).mode & 0o777).toBe(0o600);

    vi.resetModules();
    const reloaded = await import("../src/pairing/storage.js");
    const second = await reloaded.getOrCreateEd25519Keypair();
    expect(Buffer.from(second.publicKey)).toEqual(Buffer.from(first.publicKey));
  });
});

describe("paired devices", () => {
  test("re-pairing replaces the same key in any base64 spelling", async () => {
    isolatedHome();
    const storage = await import("../src/pairing/storage.js");
    await storage.addPeer({
      name: "Pixel",
      remote_epk: PHONE_A.toString("base64url"),
      paired_at: "2026-01-01T00:00:00Z",
    });
    await storage.addPeer({
      name: "Pixel 10",
      remote_epk: PHONE_A.toString("base64"),
      paired_at: "2026-02-01T00:00:00Z",
    });
    await storage.addPeer({
      name: "Tablet",
      remote_epk: PHONE_B.toString("base64"),
      paired_at: "2026-02-01T00:00:00Z",
    });

    const peers = await storage.listPeers();
    expect(peers.map((peer) => peer.name)).toEqual(["Pixel 10", "Tablet"]);
    expect(storage.isPairedKey(PHONE_A.toString("base64url"), peers)).toBe(true);
    expect(storage.isPairedKey(Buffer.alloc(32, 9).toString("base64"), peers)).toBe(false);
  });

  test("unpair by name or key prefix", async () => {
    isolatedHome();
    const storage = await import("../src/pairing/storage.js");
    await storage.addPeer({
      name: "Pixel",
      remote_epk: PHONE_A.toString("base64"),
      paired_at: "x",
    });
    await storage.addPeer({
      name: "Tablet",
      remote_epk: PHONE_B.toString("base64"),
      paired_at: "x",
    });

    expect((await storage.removePeers("Pixel")).map((peer) => peer.name)).toEqual(["Pixel"]);
    expect(await storage.removePeers("nothing")).toEqual([]);
    expect(
      (await storage.removePeers(PHONE_B.toString("base64").slice(0, 8))).map((peer) => peer.name),
    ).toEqual(["Tablet"]);
    expect(await storage.listPeers()).toEqual([]);
  });

  test("sees edits made by another process", async () => {
    const home = isolatedHome();
    const storage = await import("../src/pairing/storage.js");
    await storage.addPeer({
      name: "Pixel",
      remote_epk: PHONE_A.toString("base64"),
      paired_at: "x",
    });
    expect(await storage.listPeers()).toHaveLength(1);

    const file = join(home, "peers.json");
    const before = statSync(file).mtimeMs;
    writeFileSync(file, JSON.stringify({ peers: [] }));
    // Some file systems have coarse timestamps; make sure the change is visible.
    if (statSync(file).mtimeMs === before) {
      const { utimesSync } = await import("node:fs");
      utimesSync(file, new Date(), new Date(before + 1_000));
    }
    expect(await storage.listPeers()).toEqual([]);
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ peers: [] });
  });
});

describe("pairing tokens", () => {
  test("are 16 bytes, the length the app's QR parser accepts", async () => {
    isolatedHome();
    const { issuePendingPairToken } = await import("../src/pairing/token_store.ts");
    const token = issuePendingPairToken().token;
    expect(Buffer.from(token, "base64url")).toHaveLength(16);
  });
});
