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
    },
    close() {},
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
  return { call, connection };
}

test("a phone sends a file in and takes one back over its connection", async () => {
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), "baya-phone-")));
  dirs.push(cwd);
  const { call, connection } = phone(cwd);
  const begun = await call("_baya/upload_begin", { sessionId: "s", name: "a.txt", size: 5 });
  await call("_baya/upload_chunk", {
    uploadId: begun["uploadId"],
    offset: 0,
    data: Buffer.from("hello").toString("base64"),
  });
  const done = await call("_baya/upload_finish", { uploadId: begun["uploadId"] });
  expect(done["path"]).toBe(join(cwd, ".baya", "uploads", "a.txt"));
  expect(readFileSync(done["path"] as string, "utf8")).toBe("hello");

  writeFileSync(join(cwd, "out.txt"), "back");
  const piece = await call("_baya/download", {
    sessionId: "s",
    path: join(cwd, "out.txt"),
    offset: 0,
    length: 1024,
  });
  expect(Buffer.from(piece["data"] as string, "base64").toString()).toBe("back");
  await expect(
    call("_baya/download", { sessionId: "s", path: "/etc/hostname", offset: 0, length: 1 }),
  ).rejects.toThrow(/outside/);

  // A phone that goes away mid-upload leaves no part file behind.
  await call("_baya/upload_begin", { sessionId: "s", name: "b.txt", size: 9 });
  expect(readdirSync(join(cwd, ".baya", "uploads"))).toHaveLength(2);
  connection.closed();
  await new Promise((r) => setTimeout(r, 50));
  expect(readdirSync(join(cwd, ".baya", "uploads"))).toEqual(["a.txt"]);
});
