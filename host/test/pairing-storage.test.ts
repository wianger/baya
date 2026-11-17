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

describe.runIf(process.platform === "linux")("Linux identity", () => {
  /** A keyring holding [stored] (or nothing), as the kernel's after a restart. */
  function keyring(stored: string | null): void {
    vi.doMock("@napi-rs/keyring", () => ({
      AsyncEntry: class {
        getPassword = async () => stored;
        setPassword = async () => {};
      },
    }));
  }

  afterEach(() => {
    vi.doUnmock("@napi-rs/keyring");
  });

  test("a key still in the keyring moves to the file and stays", async () => {
    const home = isolatedHome();
    delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
    const pk = Buffer.alloc(32, 5).toString("base64");
    keyring(JSON.stringify({ pk, sk: Buffer.alloc(64, 6).toString("base64") }));
    const storage = await import("../src/pairing/storage.js");
    const moved = await storage.getOrCreateEd25519Keypair();
    expect(Buffer.from(moved.publicKey).toString("base64")).toBe(pk);
    expect(JSON.parse(readFileSync(join(home, "identity.json"), "utf8")).pk).toBe(pk);

    // The restart empties the keyring; the file keeps the key.
    vi.resetModules();
    keyring(null);
    const later = await import("../src/pairing/storage.js");
    const kept = await later.getOrCreateEd25519Keypair();
    expect(Buffer.from(kept.publicKey).toString("base64")).toBe(pk);
  });

  test("with phones paired, a lost key is not replaced by a new one", async () => {
    const home = isolatedHome();
    delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
    keyring(null);
    const storage = await import("../src/pairing/storage.js");
    await storage.addPeer({
      name: "Pixel",
      remote_epk: PHONE_A.toString("base64"),
      paired_at: "2026-01-01T00:00:00Z",
    });
    await expect(storage.getOrCreateEd25519Keypair()).rejects.toThrow(/1 device\(s\) are paired/);
    expect(existsSync(join(home, "identity.json"))).toBe(false);
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

  test("a phone that connects is marked seen and keeps its own name", async () => {
    isolatedHome();
    const storage = await import("../src/pairing/storage.js");
    await storage.addPeer({
      name: "Android device",
      remote_epk: PHONE_A.toString("base64"),
      paired_at: "x",
    });
    await storage.markSeen(PHONE_B.toString("base64url"), "Stranger");
    await storage.markSeen(PHONE_A.toString("base64url"), "Xiaomi 15");
    const [peer] = await storage.listPeers();
    expect(peer).toMatchObject({ name: "Xiaomi 15", last_seen: expect.any(String) });
    expect(await storage.listPeers()).toHaveLength(1);
    // Within a minute, a second hello writes nothing.
    const first = peer!.last_seen;
    await storage.markSeen(PHONE_A.toString("base64"));
    expect((await storage.listPeers())[0]!.last_seen).toBe(first);
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
