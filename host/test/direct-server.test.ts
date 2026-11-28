import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import WebSocket from "ws";
import { generateEd25519Keypair } from "../src/pairing/crypto.ts";
import {
  type DataFrame,
  Initiator,
  keyPairFromPrivate,
  MessageReader,
  sealData,
  sealMessage,
  x25519FromEd25519Seed,
  x25519PublicFromEd25519,
} from "../src/transport/noise.ts";

const cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const step of cleanup.splice(0).reverse()) await step();
  for (const key of ["BAYA_HOME", "BAYA_ALLOW_FILE_IDENTITY"]) delete process.env[key];
  vi.resetModules();
});

/** A host with the fake agent configured, listening for phones. */
async function setup() {
  const home = mkdtempSync(join(tmpdir(), "baya-direct-"));
  process.env["BAYA_HOME"] = home;
  process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
  writeFileSync(
    join(home, "config.json"),
    JSON.stringify({
      agents: [],
    }),
  );
  vi.resetModules();
  const { DirectServer } = await import("../src/transport/direct_server.ts");
  const { SessionHub } = await import("../src/acp/hub.ts");
  const storage = await import("../src/pairing/storage.ts");
  const tokens = await import("../src/pairing/token_store.ts");
  const hub = new SessionHub();
  await hub.start();
  const direct = new DirectServer(hub);
  const http: Server = createServer();
  http.on("upgrade", (request, socket, head) => direct.handleUpgrade(request, socket, head));
  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  cleanup.push(() => {
    hub.stop();
    http.close();
    rmSync(home, { recursive: true, force: true });
  });
  const host = await storage.getOrCreateEd25519Keypair();
  return { hub, storage, tokens, host, port: (http.address() as AddressInfo).port };
}

// biome-ignore lint/suspicious/noExplicitAny: test frames are read loosely.
type Frame = Record<string, any>;

/** A phone speaking ACP over the Noise-encrypted WebSocket. */
async function phone(port: number, hostPublic: Uint8Array) {
  const identity = generateEd25519Keypair();
  const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
  cleanup.push(() => socket.terminate());
  await new Promise((resolve) => socket.once("open", resolve));
  const initiator = new Initiator({
    prologue: Buffer.from("baya/1"),
    staticKey: keyPairFromPrivate(x25519FromEd25519Seed(identity.secretKey)),
    remoteStatic: x25519PublicFromEd25519(hostPublic),
  });
  socket.send(
    initiator.writeMessage(
      Buffer.from(JSON.stringify({ ed25519: Buffer.from(identity.publicKey).toString("base64") })),
    ),
  );
  const reply = (await new Promise((r) => socket.once("message", r))) as Buffer;
  const { session } = initiator.readMessage(reply);
  const reader = new MessageReader();
  const frames: Frame[] = [];
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    socket.once("close", (code, reason) => resolve({ code, reason: String(reason) })),
  );
  const data: DataFrame[] = [];
  socket.on("message", (raw) => {
    const message = reader.read(session.receive, raw as Buffer);
    if (Buffer.isBuffer(message)) frames.push(JSON.parse(message.toString()));
    else if (message) data.push(message);
  });
  const sendData = (stream: number, offset: number, bytes: Buffer) =>
    socket.send(sealData(session.send, stream, offset, bytes));
  const sendRaw = (bytes: Buffer) => {
    for (const frame of sealMessage(session.send, bytes)) socket.send(frame);
  };
  const send = (message: object) =>
    sendRaw(Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message })));
  let sequence = 0;
  const next = (match: (frame: Frame) => boolean, timeout = 10_000) =>
    vi.waitFor(
      () => {
        const found = frames.find(match);
        if (!found) throw new Error("not yet");
        return found;
      },
      { timeout },
    );
  const call = async (method: string, params: object = {}) => {
    const id = ++sequence;
    send({ id, method, params });
    const reply = await next((frame) => frame["id"] === id && !frame["method"]);
    if (reply["error"]) throw Object.assign(new Error(reply["error"].message), reply["error"]);
    return reply["result"] as Frame;
  };
  const updates = (sessionId: string) =>
    frames
      .filter((f) => f["method"] === "session/update" && f["params"].sessionId === sessionId)
      .map((f) => f["params"].update as Frame);
  return {
    key: Buffer.from(identity.publicKey).toString("base64"),
    socket,
    frames,
    closed,
    send,
    next,
    call,
    updates,
    data,
    sendData,
  };
}

describe("ACP over the direct connection", () => {
  test("an unpaired phone can only pair", async () => {
    const { host, port, tokens, storage } = await setup();
    const p = await phone(port, host.publicKey);
    await expect(p.call("initialize", { protocolVersion: 1 })).rejects.toMatchObject({
      code: -32000,
      data: { reason: "unpaired" },
    });
    await expect(
      p.call("_baya/pair", { token: "nope", deviceName: "Pixel" }),
    ).rejects.toMatchObject({ data: { reason: "token_unknown" } });
    const { token } = tokens.issuePendingPairToken();
    expect(await p.call("_baya/pair", { token, deviceName: "Pixel" })).toHaveProperty("hostname");
    expect((await storage.listPeers()).map((peer) => peer.name)).toEqual(["Pixel"]);
    const init = await p.call("initialize", { protocolVersion: 1 });
    expect(init).toMatchObject({
      protocolVersion: 1,
      agentCapabilities: { loadSession: true },
      _meta: { baya: { agents: [] } },
    });
  });

  test("unpairing cuts the phone off at once", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "Pixel", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    await a.call("initialize", { protocolVersion: 1 });
    await storage.removePeers("Pixel");
    await hub.refreshPeers();
    expect(await a.closed).toEqual({ code: 4003, reason: "unpaired" });
  });

  test("a forged frame ends the connection", async () => {
    const { host, port } = await setup();
    const p = await phone(port, host.publicKey);
    p.socket.send(Buffer.alloc(40, 1));
    expect(await p.closed).toEqual({ code: 4002, reason: "transport" });
    expect(p.frames).toEqual([]);
  });

  test("a handshake for another computer's key is refused", async () => {
    const { port } = await setup();
    const other = generateEd25519Keypair();
    await expect(
      Promise.race([
        phone(port, other.publicKey),
        new Promise((_, reject) => setTimeout(() => reject(new Error("no reply")), 3000)),
      ]),
    ).rejects.toThrow();
  });
});
