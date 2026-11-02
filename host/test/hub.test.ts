import { generateKeyPairSync, sign } from "node:crypto";
import { afterEach, describe, expect, test } from "vitest";
import WebSocket from "ws";
import { Hub } from "../src/hub/hub.ts";

const hubs: Hub[] = [];
const sockets: WebSocket[] = [];
afterEach(() => {
  for (const socket of sockets.splice(0)) socket.terminate();
  for (const hub of hubs.splice(0)) hub.close();
});

async function startHub(): Promise<number> {
  const hub = new Hub();
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  await hub.listen(port);
  hubs.push(hub);
  return port;
}

interface Client {
  peer: string;
  socket: WebSocket;
  frames: Array<Record<string, unknown>>;
  send(frame: object): void;
  next(match: (frame: Record<string, unknown>) => boolean): Promise<Record<string, unknown>>;
}

/** Connects and authenticates like the app and the host do. */
async function connect(port: number, room?: string, meta?: object): Promise<Client> {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x!, "base64url");
  const peer = raw.toString("base64");
  const socket = new WebSocket(`ws://127.0.0.1:${port}`);
  sockets.push(socket);
  await new Promise((resolve) => socket.once("open", resolve));
  socket.send(JSON.stringify({ type: "hello", pubkey: peer, room_id: room, room_meta: meta }));
  const challenge = JSON.parse(String(await new Promise((r) => socket.once("message", r))));
  const signature = sign(null, Buffer.from(challenge.nonce, "base64"), privateKey);
  socket.send(JSON.stringify({ type: "auth", sig: signature.toString("base64") }));
  const frames: Array<Record<string, unknown>> = [];
  const waiters: Array<{
    match: (f: Record<string, unknown>) => boolean;
    done: (f: Record<string, unknown>) => void;
  }> = [];
  socket.on("message", (data) => {
    const frame = JSON.parse(String(data)) as Record<string, unknown>;
    frames.push(frame);
    const waiter = waiters.find((w) => w.match(frame));
    if (waiter) {
      waiters.splice(waiters.indexOf(waiter), 1);
      waiter.done(frame);
    }
  });
  await new Promise((r) => setTimeout(r, 30));
  return {
    peer,
    socket,
    frames,
    send: (frame) => socket.send(JSON.stringify(frame)),
    next: (match) =>
      new Promise((done, fail) => {
        const seen = frames.find(match);
        if (seen) return done(seen);
        waiters.push({ match, done });
        setTimeout(() => fail(new Error("timed out waiting for a frame")), 2_000);
      }),
  };
}

describe("built-in hub", () => {
  test("routes envelopes between rooms of one socket and a phone", async () => {
    const port = await startHub();
    const host = await connect(port, "roomA", { name: "A", cwd: "/a" });
    const phone = await connect(port);

    host.send({ type: "room_open", room_id: "roomB", room_meta: { name: "B" } });
    expect(await host.next((f) => f["type"] === "room_opened")).toEqual({
      type: "room_opened",
      room_id: "roomB",
    });

    phone.send({ peer: host.peer, room: "roomB", ct: "AA==" });
    expect(await host.next((f) => f["ct"] === "AA==")).toEqual({
      peer: phone.peer,
      room: "main",
      to_room: "roomB",
      ct: "AA==",
    });

    host.send({ peer: phone.peer, from_room: "roomB", ct: "AQ==" });
    expect((await phone.next((f) => f["ct"] === "AQ=="))["room"]).toBe("roomB");
    // A room the socket does not own cannot be claimed.
    host.send({ peer: phone.peer, from_room: "elsewhere", ct: "Ag==" });
    expect((await phone.next((f) => f["ct"] === "Ag=="))["room"]).toBe("roomA");
  });

  test("pushes presence and rooms to subscribers", async () => {
    const port = await startHub();
    const phone = await connect(port);
    const hostKeyHolder = await connect(port, "roomA", { name: "A", cwd: "/a" });
    phone.send({ type: "subscribe_presence", peers: [hostKeyHolder.peer] });
    expect(await phone.next((f) => f["type"] === "peer_online")).toEqual({
      type: "peer_online",
      peer: hostKeyHolder.peer,
    });
    phone.send({ type: "subscribe_rooms", peers: [hostKeyHolder.peer] });
    phone.send({ type: "rooms_check", peers: [hostKeyHolder.peer] });
    const rooms = await phone.next((f) => f["type"] === "rooms");
    expect((rooms["rooms"] as Array<Record<string, unknown>>)[0]).toMatchObject({
      room_id: "roomA",
      name: "A",
      cwd: "/a",
      working: false,
    });

    hostKeyHolder.send({ type: "room_meta_update", room_id: "roomA", meta: { working: true } });
    expect(await phone.next((f) => f["type"] === "room_meta_updated")).toMatchObject({
      room_id: "roomA",
      meta: { working: true },
    });

    hostKeyHolder.socket.close();
    expect(await phone.next((f) => f["type"] === "peer_offline")).toMatchObject({
      peer: hostKeyHolder.peer,
    });
  });

  test("rejects a bad signature", async () => {
    const port = await startHub();
    const socket = new WebSocket(`ws://127.0.0.1:${port}`);
    sockets.push(socket);
    await new Promise((resolve) => socket.once("open", resolve));
    socket.send(JSON.stringify({ type: "hello", pubkey: Buffer.alloc(32, 1).toString("base64") }));
    await new Promise((r) => socket.once("message", r));
    socket.send(JSON.stringify({ type: "auth", sig: Buffer.alloc(64).toString("base64") }));
    await new Promise((resolve) => socket.once("close", resolve));
  });

  test("stores mesh versions with conflict and not-modified answers", async () => {
    const port = await startHub();
    const base = `http://127.0.0.1:${port}/mesh/${"a".repeat(64)}`;
    const envelope = (version: number) => ({
      blob: Buffer.from(JSON.stringify({ members: [], version })).toString("base64"),
      sig: "c2ln",
    });
    expect((await fetch(base)).status).toBe(404);
    const post = (version: number) =>
      fetch(base, { method: "POST", body: JSON.stringify(envelope(version)) });
    expect((await post(1)).status).toBe(200);
    expect((await post(1)).status).toBe(409);
    expect(await (await fetch(base)).json()).toMatchObject({ version: 1, sig: "c2ln" });
    expect((await fetch(`${base}?since=1`)).status).toBe(304);
    expect((await fetch(`http://127.0.0.1:${port}/health`)).status).toBe(200);
  });
});
