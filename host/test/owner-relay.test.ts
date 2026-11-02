import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";

const temporaryHomes: string[] = [];

afterEach(() => {
  delete process.env["BAYA_HOME"];
  delete process.env["BAYA_RELAY"];
  delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
  vi.resetModules();
  for (const home of temporaryHomes.splice(0)) {
    rmSync(home, { recursive: true, force: true });
  }
});

describe("standalone owner relay lifecycle", () => {
  test("keeps the local host alive when the relay is unavailable", async () => {
    // A relay that accepts TCP and hangs up before the WebSocket upgrade.
    const relay = createServer((socket) => socket.destroy());
    await new Promise<void>((resolve) => relay.listen(0, "127.0.0.1", resolve));
    const { port } = relay.address() as AddressInfo;

    const home = mkdtempSync(join(tmpdir(), "baya-relay-test-"));
    temporaryHomes.push(home);
    process.env["BAYA_HOME"] = home;
    process.env["BAYA_RELAY"] = `http://127.0.0.1:${port}`;
    process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
    vi.resetModules();

    const { OwnerRelayHost } = await import("../src/transport/owner_host.js");
    const failures: Error[] = [];
    const host = new OwnerRelayHost({
      roomId: "room",
      roomMeta: { name: "Baya", cwd: home },
      onMessage: () => {},
      onFatal: (error) => failures.push(error),
    });

    host.start();
    await vi.waitFor(() => expect(failures).toHaveLength(1));
    host.stop();
    relay.close();
  });
});

describe("end-to-end encryption through the relay", () => {
  test("a paired phone exchanges only ciphertext; plaintext, forgeries and replays are dropped", async () => {
    const { WebSocketServer } = await import("ws");
    const server = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const { port } = server.address() as AddressInfo;
    const toHost: Array<(line: string) => void> = [];
    const fromHost: Array<Record<string, string>> = [];
    server.on("connection", (socket) => {
      socket.once("message", () => {
        socket.send(JSON.stringify({ type: "challenge", nonce: Buffer.alloc(32).toString("base64") }));
        socket.once("message", () => {
          toHost.push((line) => socket.send(line));
          socket.on("message", (raw) => fromHost.push(JSON.parse(String(raw))));
        });
      });
    });

    const home = mkdtempSync(join(tmpdir(), "baya-e2e-test-"));
    temporaryHomes.push(home);
    process.env["BAYA_HOME"] = home;
    process.env["BAYA_RELAY"] = `http://127.0.0.1:${port}`;
    process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
    vi.resetModules();

    const { generateEd25519Keypair } = await import("../src/pairing/crypto.js");
    const storage = await import("../src/pairing/storage.js");
    const e2e = await import("../src/transport/e2e.js");
    const { OwnerRelayHost } = await import("../src/transport/owner_host.js");
    const hostIdentity = await storage.getOrCreateEd25519Keypair();
    const phone = generateEd25519Keypair();
    const phoneKey = Buffer.from(phone.publicKey).toString("base64");
    await storage.addPeer({ name: "Pixel", remote_epk: phoneKey, paired_at: "now" });
    const key = e2e.deriveSessionKey(phone.secretKey, phone.publicKey, hostIdentity.publicKey);

    const received: unknown[] = [];
    const host = new OwnerRelayHost({
      roomId: "room1",
      roomMeta: { name: "Baya", cwd: home },
      onMessage: (sender, message) => {
        received.push(message);
        sender.send({ type: "pong", in_reply_to: (message as { id: string }).id });
      },
    });
    host.start();
    try {
      await vi.waitFor(() => expect(toHost).toHaveLength(1));
      const deliver = (ct: Buffer) =>
        toHost[0]!(JSON.stringify({ peer: phoneKey, room: "main", ct: ct.toString("base64") }));

      deliver(Buffer.from(JSON.stringify({ type: "ping", id: "plain" })));
      deliver(e2e.seal(Buffer.alloc(32, 5), "p2h", "room1", Buffer.from('{"type":"ping","id":"forged"}')));
      const sealed = e2e.seal(key, "p2h", "room1", Buffer.from('{"type":"ping","id":"p1"}'));
      deliver(sealed);
      deliver(sealed); // replay

      await vi.waitFor(() => expect(fromHost).toHaveLength(1));
      expect(received).toEqual([{ type: "ping", id: "p1" }]);

      const reply = Buffer.from(fromHost[0]!["ct"]!, "base64");
      expect(reply.includes(Buffer.from("pong"))).toBe(false);
      const opened = e2e.open(key, "h2p", "room1", reply);
      expect(JSON.parse(opened.plaintext.toString())).toEqual({ type: "pong", in_reply_to: "p1" });
    } finally {
      host.stop();
      await new Promise((resolve) => server.close(resolve));
    }
  });
});
