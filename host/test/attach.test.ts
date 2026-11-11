import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, test, vi } from "vitest";
import { pickSession } from "../src/cli/attach.ts";
import { box, clip, hang, MarkdownLines, textWidth, wrap } from "../src/cli/tui.ts";

const FAKE_AGENT = fileURLToPath(new URL("./fixtures/fake-agent.mjs", import.meta.url));
const cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const step of cleanup.splice(0).reverse()) await step();
  delete process.env["BAYA_HOME"];
  vi.resetModules();
});

const session = (sessionId: string, title: string, updatedAt: string) => ({
  sessionId,
  title,
  updatedAt,
  cwd: "/w",
  agentName: "Pi",
  working: false,
});

test("attach picks the session named, or the latest", () => {
  const sessions = [
    session("a1b2", "Fix the login redirect", "2026-11-04T09:00:00Z"),
    session("c3d4", "Add dark mode", "2026-11-05T09:00:00Z"),
  ];
  expect(pickSession(sessions, undefined).sessionId).toBe("c3d4");
  expect(pickSession(sessions, "a1").sessionId).toBe("a1b2");
  expect(pickSession(sessions, "LOGIN").sessionId).toBe("a1b2");
  expect(() => pickSession(sessions, "nothing")).toThrow(/No session matches/);
  expect(() => pickSession([], undefined)).toThrow(/No sessions yet/);
});

test("Chinese and emoji take two columns; colours take none", () => {
  expect(textWidth("hello")).toBe(5);
  expect(textWidth("登录跳转")).toBe(8);
  expect(textWidth("ok 👍")).toBe(5);
  expect(textWidth("\u001b[1mbold\u001b[22m")).toBe(4);
});

test("text wraps at spaces, between wide characters, with a hanging indent", () => {
  expect(wrap("the quick brown fox jumps", 10)).toEqual(["the quick", "brown fox", "jumps"]);
  // A row that fills up right at a space does not start the next with it.
  expect(wrap("abcde fgh", 5)).toEqual(["abcde", "fgh"]);
  expect(wrap("登录后跳回登录页", 6)).toEqual(["登录后", "跳回登", "录页"]);
  expect(hang("one two three four", "• ", "  ", 10)).toEqual(["• one two", "  three", "  four"]);
});

test("a row cut to the width keeps whole wide characters", () => {
  expect(clip("short", 10)).toBe("short");
  expect(clip("a long footer row", 10)).toBe("a long fo…");
  expect(textWidth(clip("登录跳转回到登录页", 9))).toBeLessThanOrEqual(9);
});

test("a box fits its lines, wrapped, inside its edges", () => {
  const drawn = box(["Allow it?", "1  Allow"], { title: "Permission", width: 24 });
  expect(drawn).toHaveLength(4);
  for (const row of drawn) expect(textWidth(row)).toBe(24);
  expect(drawn[0]).toContain("Permission");
});

test("markdown renders a line at a time, the line being written changing nothing", () => {
  const md = new MarkdownLines("  ");
  expect(md.line("## 修好了")).toEqual(["  修好了"]);
  expect(md.line("- 改了 `login.ts`")).toEqual(["  • 改了 login.ts"]);
  // Previewing an opening fence, again and again, does not open it.
  expect(md.preview("```ts")).toEqual(["  ts"]);
  expect(md.preview("```ts")).toEqual(["  ts"]);
  expect(md.line("```ts")).toEqual(["  ts"]);
  expect(md.line("await x()")).toEqual(["   await x()"]);
  expect(md.preview("- not a list in code")).toEqual(["   - not a list in code"]);
  expect(md.line("```")).toEqual([]);
  expect(md.line("**done**")).toEqual(["  done"]);
});

test("a table lines up its columns once it ends", () => {
  const md = new MarkdownLines("  ", () => 60);
  expect(md.line("| attempt | before |")).toEqual([]);
  expect(md.line("|---|--:|")).toEqual([]);
  // While it streams, the rows so far show lined up.
  expect(md.preview("| 3 | 8 s |")).toEqual([
    "  attempt │ before",
    "  ────────┼───────",
    "  3       │    8 s",
  ]);
  expect(md.line("| 3 | 8 s |")).toEqual([]);
  expect(md.line("")).toEqual([
    "  attempt │ before",
    "  ────────┼───────",
    "  3       │    8 s",
    "",
  ]);
  // A table too wide for the screen lists each row instead.
  const narrow = new MarkdownLines("  ", () => 20);
  narrow.line("| name | what it does |");
  narrow.line("|---|---|");
  narrow.line("| /model | choose the model |");
  expect(narrow.flush()).toEqual(["  name: /model", "  what it does:", "    choose the model"]);
});

test("the control socket attaches a terminal that shares the session live", async () => {
  const home = mkdtempSync(join(tmpdir(), "baya-attach-"));
  process.env["BAYA_HOME"] = home;
  writeFileSync(
    join(home, "config.json"),
    JSON.stringify({
      agents: [{ id: "fake", name: "Fake", command: [process.execPath, FAKE_AGENT] }],
    }),
  );
  vi.resetModules();
  const { SessionHub } = await import("../src/acp/hub.ts");
  const { ControlServer } = await import("../src/control/server.ts");
  const hub = new SessionHub();
  await hub.start();
  const control = new ControlServer(hub, () => {});
  const info = await control.start();
  cleanup.push(async () => {
    hub.stop();
    await control.close();
    rmSync(home, { recursive: true, force: true });
  });

  const socket = connect({ host: "127.0.0.1", port: info.port });
  cleanup.push(() => void socket.destroy());
  socket.setEncoding("utf8");
  const lines: Array<Record<string, unknown>> = [];
  let buffer = "";
  socket.on("data", (chunk: string) => {
    buffer += chunk;
    for (let n = buffer.indexOf("\n"); n >= 0; n = buffer.indexOf("\n")) {
      lines.push(JSON.parse(buffer.slice(0, n)));
      buffer = buffer.slice(n + 1);
    }
  });
  await new Promise((resolve) => socket.once("connect", resolve));
  // A wrong token is refused like any control request.
  socket.write(`${JSON.stringify({ token: "nope", id: "x", command: "attach" })}\n`);
  await vi.waitFor(() => expect(lines[0]).toMatchObject({ ok: false, error: "Unauthorized." }));

  const again = connect({ host: "127.0.0.1", port: info.port });
  cleanup.push(() => void again.destroy());
  again.setEncoding("utf8");
  const got: Array<Record<string, unknown>> = [];
  let rest = "";
  again.on("data", (chunk: string) => {
    rest += chunk;
    for (let n = rest.indexOf("\n"); n >= 0; n = rest.indexOf("\n")) {
      got.push(JSON.parse(rest.slice(0, n)));
      rest = rest.slice(n + 1);
    }
  });
  await new Promise((resolve) => again.once("connect", resolve));
  const send = (message: object) =>
    again.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  again.write(`${JSON.stringify({ token: info.token, id: "a", command: "attach" })}\n`);
  await vi.waitFor(() => expect(got[0]).toMatchObject({ ok: true, data: { attached: true } }));

  const reply = async (id: number) =>
    vi.waitFor(() => {
      const found = got.find((m) => m["id"] === id && !m["method"]);
      if (!found) throw new Error("not yet");
      return found as { result: Record<string, unknown> };
    });
  send({ id: 1, method: "initialize", params: { protocolVersion: 1 } });
  await reply(1);
  send({
    id: 2,
    method: "session/new",
    params: { cwd: tmpdir(), mcpServers: [], _meta: { baya: { agent: "fake" } } },
  });
  const { sessionId } = (await reply(2)).result as { sessionId: string };
  send({
    id: 3,
    method: "session/prompt",
    params: {
      sessionId,
      prompt: [{ type: "text", text: "Hi" }],
      _meta: { baya: { messageId: "t1" } },
    },
  });
  expect((await reply(3)).result).toEqual({ stopReason: "end_turn" });
  const kinds = got
    .filter((m) => m["method"] === "session/update")
    .map((m) => (m["params"] as { update: { sessionUpdate: string } }).update.sessionUpdate);
  expect(kinds).toEqual(expect.arrayContaining(["user_message_chunk", "agent_message_chunk"]));
  // A terminal is not counted as a phone.
  expect(hub.connectedPhones).toBe(0);
});
