import { mkdtempSync, rmSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";

const homes: string[] = [];
const servers: WebSocketServer[] = [];

afterEach(async () => {
  for (const key of ["BAYA_HOME", "BAYA_RELAY", "REMOTE_PI_HOME", "BAYA_ALLOW_FILE_IDENTITY"]) {
    delete process.env[key];
  }
  vi.resetModules();
  for (const server of servers.splice(0)) {
    for (const client of server.clients) client.terminate();
    await new Promise((resolve) => server.close(resolve));
  }
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

interface FakeSocket {
  hello: Record<string, unknown>;
  socket: WebSocket;
  frames: Array<Record<string, unknown>>;
}

/** Minimal relay: hello → challenge → auth, then records every frame. */
async function fakeRelay(options: { multiplex: boolean }) {
  const server = new WebSocketServer({ port: 0, host: "127.0.0.1" });
  servers.push(server);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const sockets: FakeSocket[] = [];
  server.on("connection", (socket) => {
    socket.once("message", (hello) => {
      socket.send(JSON.stringify({ type: "challenge", nonce: Buffer.alloc(32).toString("base64") }));
      socket.once("message", () => {
        const entry: FakeSocket = { hello: JSON.parse(String(hello)), socket, frames: [] };
        sockets.push(entry);
        socket.on("message", (raw) => {
          const frame = JSON.parse(String(raw)) as Record<string, unknown>;
          entry.frames.push(frame);
          if (frame["type"] === "room_open" && options.multiplex) {
            socket.send(JSON.stringify({ type: "room_opened", room_id: frame["room_id"] }));
          }
        });
      });
    });
  });
  const { port } = server.address() as AddressInfo;
  const home = mkdtempSync(join(tmpdir(), "baya-hub-test-"));
  homes.push(home);
  process.env["BAYA_HOME"] = home;
  process.env["REMOTE_PI_HOME"] = join(home, "legacy");
  process.env["BAYA_RELAY"] = `http://127.0.0.1:${port}`;
  process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
  vi.resetModules();
  const { RelayHub } = await import("../src/transport/relay_hub.js");
  return { sockets, hub: new RelayHub({ ackTimeoutMs: 150 }) };
}

describe("relay hub", () => {
  test("all rooms share one socket on a multiplexing relay", async () => {
    const { sockets, hub } = await fakeRelay({ multiplex: true });
    const received: Record<string, string[]> = { a: [], b: [] };
    const a = hub.open("a", { name: "A", cwd: "/a" }, { onLine: (line) => received.a!.push(line) });
    const b = hub.open("b", { name: "B", cwd: "/b" }, { onLine: (line) => received.b!.push(line) });

    await vi.waitFor(() => expect(b.isOpen()).toBe(true));
    expect(sockets).toHaveLength(1);
    expect(sockets[0]!.hello["room_id"]).toBe("a");
    expect(sockets[0]!.frames[0]).toMatchObject({ type: "room_open", room_id: "b", room_meta: { name: "B" } });

    const socket = sockets[0]!.socket;
    socket.send(JSON.stringify({ peer: "phone", room: "main", to_room: "b", ct: "x" }));
    socket.send(JSON.stringify({ peer: "phone", room: "main", to_room: "a", ct: "y" }));
    await vi.waitFor(() => expect(received.a!.length + received.b!.length).toBe(2));
    expect(JSON.parse(received.b![0]!).ct).toBe("x");
    expect(JSON.parse(received.a![0]!).ct).toBe("y");

    a.send({ peer: "phone", ct: "1" });
    b.send({ peer: "phone", ct: "2" });
    b.updateMeta({ working: true });
    await vi.waitFor(() => expect(sockets[0]!.frames).toHaveLength(4));
    expect(sockets[0]!.frames.slice(1)).toEqual([
      { peer: "phone", ct: "1" },
      { peer: "phone", ct: "2", from_room: "b" },
      { type: "room_meta_update", room_id: "b", meta: { working: true } },
    ]);

    a.close();
    await vi.waitFor(() => expect(sockets[0]!.frames.at(-1)).toEqual({ type: "room_close", room_id: "a" }));
    expect(b.isOpen()).toBe(true);
    b.close();
  });

  test("an old relay that ignores room_open gets one socket per room", async () => {
    const { sockets, hub } = await fakeRelay({ multiplex: false });
    const a = hub.open("a", { name: "A", cwd: "/a" }, { onLine: () => {} });
    const b = hub.open("b", { name: "B", cwd: "/b" }, { onLine: () => {} });
    await vi.waitFor(() => expect(sockets).toHaveLength(2), { timeout: 2_000 });
    expect(sockets.map((s) => s.hello["room_id"]).sort()).toEqual(["a", "b"]);
    await vi.waitFor(() => expect(a.isOpen() && b.isOpen()).toBe(true));

    // Later rooms skip the probe and connect on their own right away.
    const c = hub.open("c", { name: "C", cwd: "/c" }, { onLine: () => {} });
    await vi.waitFor(() => expect(sockets).toHaveLength(3));
    expect(sockets[2]!.frames).toEqual([]);
    for (const link of [a, b, c]) link.close();
  });
});
