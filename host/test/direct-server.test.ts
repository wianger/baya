import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
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

const FAKE_AGENT = fileURLToPath(new URL("./fixtures/fake-agent.mjs", import.meta.url));

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
      agents: [{ id: "fake", name: "Fake", command: [process.execPath, FAKE_AGENT] }],
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
  test("files go both ways as data frames on the encrypted socket", async () => {
    const { host, port, storage, hub } = await setup();
    const p = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: p.key, paired_at: "now" });
    await hub.refreshPeers();
    await p.call("initialize", { protocolVersion: 1 });
    const cwd = mkdtempSync(join(tmpdir(), "baya-files-"));
    cleanup.push(() => rmSync(cwd, { recursive: true, force: true }));
    const { sessionId } = (await p.call("session/new", {
      cwd,
      mcpServers: [],
      _meta: { baya: { agent: "fake" } },
    })) as { sessionId: string };

    // 200 kB up, in data frames, acknowledged as it lands.
    const content = Buffer.alloc(200_000);
    for (let i = 0; i < content.length; i++) content[i] = i % 251;
    const begun = await p.call("_baya/upload_begin", {
      sessionId,
      name: "photo.bin",
      size: content.length,
      stream: 5,
    });
    for (let at = 0; at < content.length; at += 64_000) {
      p.sendData(5, at, content.subarray(at, at + 64_000));
    }
    await p.next(
      (f) => f["method"] === "_baya/upload_progress" && f["params"].received === content.length,
    );
    const done = await p.call("_baya/upload_finish", { uploadId: begun["uploadId"] });
    expect(readFileSync(done["path"] as string)).toEqual(content);

    // And back down from an offset, then the end.
    const opened = await p.call("_baya/download_open", {
      sessionId,
      path: done["path"],
      offset: 1000,
      stream: 6,
    });
    expect(opened["size"]).toBe(content.length);
    await p.next((f) => f["method"] === "_baya/stream_end" && f["params"].stream === 6);
    const got = Buffer.concat(p.data.filter((d) => d.stream === 6).map((d) => d.bytes));
    expect(got).toEqual(content.subarray(1000));
  });

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
      _meta: { baya: { agents: [{ id: "fake", name: "Fake", available: true }] } },
    });
  });

  test("a conversation streams, replays, and is shared between phones", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    const b = await phone(port, host.publicKey);
    for (const p of [a, b]) {
      await storage.addPeer({ name: "P", remote_epk: p.key, paired_at: "now" });
    }
    await hub.refreshPeers();
    await a.call("initialize", { protocolVersion: 1 });
    await b.call("initialize", { protocolVersion: 1 });
    // Two phones, each counted once.
    expect(hub.connectedPhones).toBe(2);

    const created = await a.call("session/new", {
      cwd: tmpdir(),
      mcpServers: [],
      _meta: { baya: { agent: "fake" } },
    });
    const id = created["sessionId"] as string;
    expect(created["configOptions"][0]).toMatchObject({ id: "model", currentValue: "fast" });
    // Every phone hears about the new session.
    await b.next(
      (f) => f["method"] === "_baya/session_changed" && f["params"].session.sessionId === id,
    );

    const reply = await a.call("session/prompt", {
      sessionId: id,
      prompt: [{ type: "text", text: "Hi there" }],
      _meta: { baya: { messageId: "m1" } },
    });
    expect(reply).toEqual({ stopReason: "end_turn" });
    expect(a.updates(id).map((u) => u["sessionUpdate"])).toEqual(
      expect.arrayContaining([
        "user_message_chunk",
        "agent_thought_chunk",
        "agent_message_chunk",
        "tool_call",
        "tool_call_update",
        "usage_update",
      ]),
    );
    expect(a.updates(id)).toContainEqual({
      sessionUpdate: "user_message_chunk",
      content: { type: "text", text: "Hi there" },
      messageId: "m1",
    });

    // The other phone loads the session and gets the folded history.
    await b.call("session/load", { sessionId: id, cwd: tmpdir(), mcpServers: [] });
    const replay = b.updates(id);
    expect(replay).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "Hello world" },
    });
    expect(replay).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        status: "completed",
      }),
    );
    expect(replay).toContainEqual(expect.objectContaining({ sessionUpdate: "usage_update" }));

    // The first prompt titles the session.
    const listed = await b.call("session/list");
    expect(listed["sessions"]).toEqual([
      expect.objectContaining({
        sessionId: id,
        title: "Hi there",
        _meta: { baya: expect.objectContaining({ agent: "fake", working: false, running: true }) },
      }),
    ]);

    // A setting changed on one phone reaches the other.
    await a.call("session/set_config_option", { sessionId: id, configId: "model", value: "smart" });
    await b.next(
      (f) =>
        f["params"]?.update?.sessionUpdate === "config_option_update" &&
        f["params"].update.configOptions[0].currentValue === "smart",
    );
  });

  test("a phone that comes back gets only what it missed", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    const b = await phone(port, host.publicKey);
    for (const p of [a, b])
      await storage.addPeer({ name: "P", remote_epk: p.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", { cwd: tmpdir(), mcpServers: [] })) as {
      sessionId: string;
    };
    await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "first" }] });
    const loaded = await b.call("session/load", { sessionId, cwd: tmpdir(), mcpServers: [] });
    const { cursor, resumed } = loaded["_meta"].baya;
    expect(resumed).toBe(false);
    expect(cursor).toMatchObject({ epoch: expect.any(String), seq: expect.any(Number) });
    b.socket.terminate();

    // While b is away, the conversation goes on; live updates are numbered.
    await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "second" }] });
    const live = a.frames.filter(
      (f) => f["method"] === "session/update" && f["params"].sessionId === sessionId,
    );
    expect(live.at(-1)?.["params"]._meta.baya.seq).toBeGreaterThan(cursor.seq);

    const back = await phone(port, host.publicKey);
    await storage.addPeer({ name: "Q", remote_epk: back.key, paired_at: "now" });
    await hub.refreshPeers();
    const again = await back.call("session/load", {
      sessionId,
      cwd: tmpdir(),
      mcpServers: [],
      _meta: { baya: { resume: cursor } },
    });
    expect(again["_meta"].baya.resumed).toBe(true);
    expect(again["_meta"].baya.cursor.seq).toBe(live.at(-1)?.["params"]._meta.baya.seq);
    const caughtUp = back.updates(sessionId);
    expect(caughtUp).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "second" },
      }),
    );
    expect(caughtUp).not.toContainEqual(
      expect.objectContaining({
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "first" },
      }),
    );

    // A cursor from another run of the host gets the whole history instead.
    const stranger = await phone(port, host.publicKey);
    await storage.addPeer({ name: "R", remote_epk: stranger.key, paired_at: "now" });
    await hub.refreshPeers();
    const full = await stranger.call("session/load", {
      sessionId,
      cwd: tmpdir(),
      mcpServers: [],
      _meta: { baya: { resume: { epoch: "gone", seq: cursor.seq } } },
    });
    expect(full["_meta"].baya.resumed).toBe(false);
    expect(stranger.updates(sessionId)).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "first" },
      }),
    );
  });

  test("a session Baya holds opens at once, the agent starting behind it", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", { cwd: tmpdir(), mcpServers: [] })) as {
      sessionId: string;
    };
    await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "first" }] });
    await a.call("session/close", { sessionId });
    hub.get(sessionId)!.stop();
    // The agent now never answers: a load that waited for it would hang.
    writeFileSync(
      join(process.env["BAYA_HOME"]!, "config.json"),
      JSON.stringify({
        agents: [
          {
            id: "fake",
            name: "Fake",
            command: [process.execPath, "-e", "setInterval(() => {}, 1000)"],
          },
        ],
      }),
    );
    const b = await phone(port, host.publicKey);
    await storage.addPeer({ name: "Q", remote_epk: b.key, paired_at: "now" });
    await hub.refreshPeers();
    const started = Date.now();
    const loaded = await b.call("session/load", { sessionId, cwd: tmpdir(), mcpServers: [] });
    expect(Date.now() - started).toBeLessThan(2_000);
    expect(loaded["configOptions"]?.[0]).toMatchObject({ id: "model" });
    expect(b.updates(sessionId)).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "first" },
      }),
    );
    hub.get(sessionId)!.stop();
  });

  test("the first phone to answer a permission request wins", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    const b = await phone(port, host.publicKey);
    for (const p of [a, b])
      await storage.addPeer({ name: "P", remote_epk: p.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", {
      cwd: tmpdir(),
      mcpServers: [],
    })) as { sessionId: string };
    await b.call("session/load", { sessionId, cwd: tmpdir(), mcpServers: [] });

    const turn = a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "ask" }] });
    const askA = await a.next((f) => f["method"] === "session/request_permission");
    const askB = await b.next((f) => f["method"] === "session/request_permission");
    expect(askA["params"]).toMatchObject({ sessionId, toolCall: { toolCallId: "t1" } });
    b.send({ id: askB["id"], result: { outcome: { outcome: "selected", optionId: "yes" } } });
    // The other phone's question is withdrawn.
    await a.next((f) => f["method"] === "$/cancel_request" && f["params"].requestId === askA["id"]);
    expect(await turn).toEqual({ stopReason: "end_turn" });
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: " (selected:yes)" },
    });
  });

  test("cancel ends the turn; a crashed agent restarts on the next prompt", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", {
      cwd: tmpdir(),
      mcpServers: [],
    })) as { sessionId: string };

    const turn = a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "wait" }] });
    await a.next((f) => f["params"]?.update?.sessionUpdate === "tool_call");
    expect(hub.get(sessionId)?.working).toBe(true);
    a.send({ method: "session/cancel", params: { sessionId } });
    expect(await turn).toEqual({ stopReason: "cancelled" });

    await expect(
      a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "exit" }] }),
    ).rejects.toThrow(/stopped/);
    // The agent reloads its own session; its replay is not shown twice.
    expect(
      await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "again" }] }),
    ).toEqual({ stopReason: "end_turn" });
    expect(a.updates(sessionId)).not.toContainEqual(
      expect.objectContaining({ content: { type: "text", text: "remembered" } }),
    );
  });

  test("files and terminals run on the computer; phones see terminal output", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", { cwd: tmpdir(), mcpServers: [] })) as {
      sessionId: string;
    };
    const file = join(mkdtempSync(join(tmpdir(), "baya-fs-")), "nested", "a.txt");
    await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: `file ${file}` }] });
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "read:two" },
    });

    await a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "terminal" }] });
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "exit:0 from the terminal" },
    });
    const terminal = await a.next(
      (f) => f["method"] === "_baya/terminal" && f["params"].exitStatus !== null,
    );
    expect(terminal["params"]).toMatchObject({ sessionId, exitStatus: { exitCode: 0 } });
    expect(terminal["params"].output).toContain("from the terminal");

    // A phone loading the session later gets the terminal too.
    const b = await phone(port, host.publicKey);
    await storage.addPeer({ name: "Q", remote_epk: b.key, paired_at: "now" });
    await hub.refreshPeers();
    await b.call("session/load", { sessionId, cwd: tmpdir(), mcpServers: [] });
    await b.next(
      (f) => f["method"] === "_baya/terminal" && f["params"].output.includes("terminal"),
    );
  });

  test("elicitation forms go to the phone; sign-in failures name the agent", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const { sessionId } = (await a.call("session/new", { cwd: tmpdir(), mcpServers: [] })) as {
      sessionId: string;
    };
    const turn = a.call("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "elicit" }],
    });
    const ask = await a.next((f) => f["method"] === "elicitation/create");
    expect(ask["params"]).toMatchObject({ sessionId, mode: "form", message: "Which branch?" });
    a.send({ id: ask["id"], result: { action: "accept", content: { branch: "main" } } });
    await turn;
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "accept:main" },
    });

    await expect(
      a.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "auth" }] }),
    ).rejects.toMatchObject({ code: -32000, data: { reason: "auth_required", agent: "fake" } });
    expect(await a.call("_baya/agent_auth", { agent: "fake" })).toEqual({
      authMethods: [{ id: "browser", name: "Sign in with a browser" }],
      logout: true,
    });
    expect(await a.call("_baya/authenticate", { agent: "fake", methodId: "browser" })).toEqual({});
  });

  test("the agent's own conversations can be adopted, with their history", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const listed = await a.call("_baya/agent_sessions", { agent: "fake", cwd: tmpdir() });
    expect(listed["sessions"]).toContainEqual(
      expect.objectContaining({ sessionId: "old-1", title: "Earlier work" }),
    );
    const { sessionId } = (await a.call("session/new", {
      cwd: tmpdir(),
      mcpServers: [],
      _meta: { baya: { agent: "fake", agentSessionId: "old-1" } },
    })) as { sessionId: string };
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "remembered" },
    });
    // The adopted history keeps the user's side too, and nothing in it is
    // taken for startup chatter.
    expect(a.updates(sessionId)).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "from the agent's history" },
      }),
    );
    expect(JSON.stringify(a.updates(sessionId))).not.toContain("startup");
    const again = await a.call("_baya/agent_sessions", { agent: "fake", cwd: tmpdir() });
    expect(again["sessions"].map((s: Frame) => s["sessionId"])).not.toContain("old-1");
  });

  test("what an agent says before the first prompt is marked as startup", async () => {
    const { host, port, storage, hub } = await setup();
    const a = await phone(port, host.publicKey);
    await storage.addPeer({ name: "P", remote_epk: a.key, paired_at: "now" });
    await hub.refreshPeers();
    const cwd = mkdtempSync(join(tmpdir(), "banner-"));
    const { sessionId } = (await a.call("session/new", {
      cwd,
      mcpServers: [],
      _meta: { baya: { agent: "fake" } },
    })) as { sessionId: string };
    for (let i = 0; i < 50 && !JSON.stringify(a.updates(sessionId)).includes("fake v1"); i++) {
      await new Promise((done) => setTimeout(done, 20));
    }
    expect(a.updates(sessionId)).toContainEqual({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "fake v1, skills loaded" },
      _meta: { baya: { startup: true } },
    });
    await a.call("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "hi" }],
    });
    const replies = a
      .updates(sessionId)
      .filter((u: Frame) => u["sessionUpdate"] === "agent_message_chunk");
    expect(replies.filter((u: Frame) => JSON.stringify(u).includes("startup"))).toHaveLength(1);
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
