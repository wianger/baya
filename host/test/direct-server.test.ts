import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import WebSocket from "ws";

const cleanup: Array<() => void> = [];
afterEach(() => {
  for (const step of cleanup.splice(0)) step();
  for (const key of ["BAYA_HOME", "BAYA_ALLOW_FILE_IDENTITY"]) delete process.env[key];
  vi.resetModules();
});

async function setup() {
  const home = mkdtempSync(join(tmpdir(), "baya-direct-"));
  process.env["BAYA_HOME"] = home;
  process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
  vi.resetModules();
  const { DirectServer } = await import("../src/transport/direct_server.ts");
  const storage = await import("../src/pairing/storage.ts");
  const direct = new DirectServer();
  const http: Server = createServer();
  http.on("upgrade", (request, socket, head) => direct.handleUpgrade(request, socket, head));
  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  cleanup.push(() => {
    http.close();
    rmSync(home, { recursive: true, force: true });
  });
  const hostKey = Buffer.from((await storage.getOrCreateEd25519Keypair()).publicKey).toString(
    "base64",
  );
  return { direct, storage, hostKey, port: (http.address() as AddressInfo).port };
}

async function phone(port: number) {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const key = Buffer.from(publicKey.export({ format: "jwk" }).x!, "base64url").toString("base64");
  const socket = new WebSocket(`ws://127.0.0.1:${port}/baya-pair/wsl`);
  cleanup.push(() => socket.terminate());
  await new Promise((resolve) => socket.once("open", resolve));
  socket.send(JSON.stringify({ type: "hello", pubkey: key, room_id: "main" }));
  const challenge = JSON.parse(String(await new Promise((r) => socket.once("message", r))));
  socket.send(
    JSON.stringify({
      type: "auth",
      sig: sign(null, Buffer.from(challenge.nonce, "base64"), privateKey).toString("base64"),
    }),
  );
  const frames: Array<Record<string, unknown>> = [];
  socket.on("message", (data) => frames.push(JSON.parse(String(data))));
  await new Promise((r) => setTimeout(r, 30));
  return {
    key,
    frames,
    send: (frame: object) => socket.send(JSON.stringify(frame)),
    next: (match: (frame: Record<string, unknown>) => boolean) =>
      vi.waitFor(() => {
        const found = frames.find(match);
        if (!found) throw new Error("not yet");
        return found;
      }),
  };
}

describe("direct server", () => {
  test("a paired phone sees this computer, its rooms, and talks to them", async () => {
    const { direct, storage, hostKey, port } = await setup();
    const lines: string[] = [];
    const link = direct.open(
      "room1",
      { name: "Review", cwd: "/code" },
      {
        onEnvelope: (peer, ct) => lines.push(JSON.stringify({ peer, ct })),
      },
    );
    const p = await phone(port);
    await storage.addPeer({ name: "Pixel", remote_epk: p.key, paired_at: "now" });

    p.send({ type: "subscribe_presence", peers: [hostKey] });
    expect(await p.next((f) => f["type"] === "peer_online")).toEqual({
      type: "peer_online",
      peer: hostKey,
    });
    p.send({ type: "subscribe_rooms", peers: [hostKey] });
    p.send({ type: "rooms_check", peers: [hostKey] });
    const rooms = await p.next((f) => f["type"] === "rooms");
    expect(rooms["rooms"]).toEqual([
      expect.objectContaining({ room_id: "room1", name: "Review", cwd: "/code", working: false }),
    ]);

    p.send({ peer: hostKey, room: "room1", ct: "AA==" });
    await vi.waitFor(() => expect(lines).toHaveLength(1));
    expect(JSON.parse(lines[0]!)).toEqual({ peer: p.key, ct: "AA==" });

    link.send({ peer: p.key, ct: "AQ==" });
    expect(await p.next((f) => f["ct"] === "AQ==")).toEqual({
      peer: hostKey,
      room: "room1",
      to_room: "main",
      ct: "AQ==",
    });

    link.updateMeta({ working: true });
    expect(await p.next((f) => f["type"] === "room_meta_updated")).toMatchObject({
      peer: hostKey,
      room_id: "room1",
      meta: { working: true },
    });
    link.close();
    expect(await p.next((f) => f["type"] === "room_ended")).toMatchObject({ room_id: "room1" });
  });

  test("an unpaired phone may only send envelopes (pairing), never read rooms", async () => {
    const { direct, hostKey, port } = await setup();
    const lines: string[] = [];
    direct.open(
      "room1",
      { name: "Review", cwd: "/code" },
      { onEnvelope: (peer, ct) => lines.push(JSON.stringify({ peer, ct })) },
    );
    const p = await phone(port);
    p.send({ type: "subscribe_presence", peers: [hostKey] });
    p.send({ type: "rooms_check", peers: [hostKey] });
    p.send({ peer: hostKey, room: "room1", ct: "AA==" });
    await vi.waitFor(() => expect(lines).toHaveLength(1));
    await new Promise((r) => setTimeout(r, 100));
    expect(p.frames).toEqual([]);
  });
});
