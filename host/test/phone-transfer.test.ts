import {
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import type { SessionHub } from "../src/acp/hub.ts";
import type { Json } from "../src/acp/jsonrpc.ts";
import { PhoneConnection } from "../src/acp/phone.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** A paired phone talking to a hub with one session in [cwd]. */
function phone(cwd: string) {
  const replies = new Map<number, Json>();
  const notes: Json[] = [];
  const frames: Array<{ stream: number; offset: number; bytes: Buffer }> = [];
  const hub = {
    connect() {},
    disconnect() {},
    isPaired: () => true,
    get: (id: string) => (id === "s" ? { id, record: { cwd } } : undefined),
  } as unknown as SessionHub;
  const connection = new PhoneConnection({
    key: "k",
    hub,
    send: (message) => {
      if (typeof message["id"] === "number") replies.set(message["id"], message);
      else notes.push(message);
    },
    close() {},
    sendData: async (stream, offset, bytes) => {
      frames.push({ stream, offset, bytes });
    },
  });
  let id = 0;
  const call = async (method: string, params: Json): Promise<Json> => {
    const mine = ++id;
    connection.receive({ jsonrpc: "2.0", id: mine, method, params });
    for (let i = 0; i < 200 && !replies.has(mine); i++) await new Promise((r) => setTimeout(r, 5));
    const reply = replies.get(mine)!;
    if (reply["error"]) throw new Error((reply["error"] as Json)["message"] as string);
    return reply["result"] as Json;
  };
  const until = async (check: () => boolean) => {
    for (let i = 0; i < 200 && !check(); i++) await new Promise((r) => setTimeout(r, 5));
  };
  return { call, connection, notes, frames, until };
}

test("a phone sends a file in as data frames and streams one back", async () => {
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), "baya-phone-")));
  dirs.push(cwd);
  const { call, connection, notes, frames, until } = phone(cwd);
  const begun = await call("_baya/upload_begin", {
    sessionId: "s",
    name: "a.txt",
    size: 5,
    stream: 3,
  });
  connection.receiveData({ stream: 3, offset: 0, bytes: Buffer.from("hello") });
  await until(() => notes.some((n) => n["method"] === "_baya/upload_progress"));
  expect(notes.at(-1)).toMatchObject({
    method: "_baya/upload_progress",
    params: { uploadId: begun["uploadId"], received: 5 },
  });
  const done = await call("_baya/upload_finish", { uploadId: begun["uploadId"] });
  expect(readFileSync(done["path"] as string, "utf8")).toBe("hello");

  writeFileSync(join(cwd, "out.bin"), Buffer.alloc(70_000, 1));
  const opened = await call("_baya/download_open", {
    sessionId: "s",
    path: join(cwd, "out.bin"),
    offset: 1000,
    stream: 8,
  });
  expect(opened).toEqual({ name: "out.bin", size: 70_000 });
  await until(() => notes.some((n) => n["method"] === "_baya/stream_end"));
  expect(frames.map((f) => [f.stream, f.offset, f.bytes.length])).toEqual([
    [8, 1000, 64_000],
    [8, 65_000, 5_000],
  ]);
  expect(notes.at(-1)).toMatchObject({
    method: "_baya/stream_end",
    params: { stream: 8, size: 70_000, sent: 70_000 },
  });
  await expect(
    call("_baya/download_open", { sessionId: "s", path: "/etc/hostname", offset: 0, stream: 9 }),
  ).rejects.toThrow(/outside/);
});

test("an upload outlives its connection and resumes on the next", async () => {
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), "baya-phone-")));
  dirs.push(cwd);
  const first = phone(cwd);
  const begun = await first.call("_baya/upload_begin", {
    sessionId: "s",
    name: "b.txt",
    size: 6,
    stream: 1,
  });
  first.connection.receiveData({ stream: 1, offset: 0, bytes: Buffer.from("abc") });
  await first.until(() => first.notes.length > 0);
  first.connection.closed();
  expect(readdirSync(join(cwd, ".baya", "uploads"))).toHaveLength(1);

  const second = phone(cwd);
  const resumed = await second.call("_baya/upload_resume", {
    uploadId: begun["uploadId"],
    stream: 2,
  });
  expect(resumed).toEqual({ received: 3 });
  second.connection.receiveData({ stream: 2, offset: 3, bytes: Buffer.from("def") });
  await second.until(() => second.notes.length > 0);
  const done = await second.call("_baya/upload_finish", { uploadId: begun["uploadId"] });
  expect(readFileSync(done["path"] as string, "utf8")).toBe("abcdef");
});
