import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { DirectServer, RoomHandlers } from "../src/transport/direct_server.ts";

const temporaryHomes: string[] = [];

afterEach(() => {
  delete process.env["BAYA_HOME"];
  delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
  vi.resetModules();
  for (const home of temporaryHomes.splice(0)) {
    rmSync(home, { recursive: true, force: true });
  }
});

describe("end-to-end encryption", () => {
  test("a paired phone exchanges only ciphertext; plaintext, forgeries and replays are dropped", async () => {
    const home = mkdtempSync(join(tmpdir(), "baya-e2e-test-"));
    temporaryHomes.push(home);
    process.env["BAYA_HOME"] = home;
    process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
    vi.resetModules();

    const { generateEd25519Keypair } = await import("../src/pairing/crypto.ts");
    const storage = await import("../src/pairing/storage.ts");
    const e2e = await import("../src/transport/e2e.ts");
    const { OwnerHost } = await import("../src/transport/owner_host.ts");
    const hostIdentity = await storage.getOrCreateEd25519Keypair();
    const phone = generateEd25519Keypair();
    const phoneKey = Buffer.from(phone.publicKey).toString("base64");
    await storage.addPeer({ name: "Pixel", remote_epk: phoneKey, paired_at: "now" });
    const key = e2e.deriveSessionKey(phone.secretKey, phone.publicKey, hostIdentity.publicKey);

    let handlers: RoomHandlers | null = null;
    const sent: Array<{ peer: string; ct: string }> = [];
    const direct = {
      open: (_room: string, _meta: unknown, h: RoomHandlers) => {
        handlers = h;
        return {
          isOpen: () => true,
          send: (envelope: { peer: string; ct: string }) => sent.push(envelope),
          updateMeta: () => {},
          close: () => {},
        };
      },
    } as unknown as DirectServer;

    const received: unknown[] = [];
    const host = new OwnerHost({
      roomId: "room1",
      roomMeta: { name: "Baya", cwd: home },
      direct,
      onMessage: (sender, message) => {
        received.push(message);
        sender.send({ type: "pong", in_reply_to: (message as { id: string }).id });
      },
    });
    host.start();
    try {
      const deliver = (ct: Buffer) => handlers!.onEnvelope(phoneKey, ct.toString("base64"));
      deliver(Buffer.from(JSON.stringify({ type: "ping", id: "plain" })));
      deliver(
        e2e.seal(Buffer.alloc(32, 5), "p2h", "room1", Buffer.from('{"type":"ping","id":"forged"}')),
      );
      const sealed = e2e.seal(key, "p2h", "room1", Buffer.from('{"type":"ping","id":"p1"}'));
      deliver(sealed);
      deliver(sealed); // replay

      await vi.waitFor(() => expect(sent).toHaveLength(1));
      expect(received).toEqual([{ type: "ping", id: "p1" }]);
      expect(sent[0]!.peer).toBe(phoneKey);
      const reply = Buffer.from(sent[0]!.ct, "base64");
      expect(reply.includes(Buffer.from("pong"))).toBe(false);
      const opened = e2e.open(key, "h2p", "room1", reply);
      expect(JSON.parse(opened.plaintext.toString())).toEqual({ type: "pong", in_reply_to: "p1" });
    } finally {
      host.stop();
    }
  });
});
