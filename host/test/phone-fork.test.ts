import { expect, test } from "vitest";
import type { SessionHub } from "../src/acp/hub.ts";
import type { Json } from "../src/acp/jsonrpc.ts";
import { PhoneConnection } from "../src/acp/phone.ts";

function phone() {
  const forks: Json[] = [];
  const created: Json[] = [];
  const source = {
    id: "s",
    title: "Add dark mode",
    record: { cwd: "/w", agent: "claude" },
  };
  const hub = {
    connect() {},
    disconnect() {},
    isPaired: () => true,
    get: (id: string) => (id === "s" ? source : undefined),
    fork: async (from: unknown, point: Json) => {
      expect(from).toBe(source);
      forks.push(point);
      return "agent-branch";
    },
    create: (cwd: string, agent: string, options: Json) => {
      created.push({ cwd, agent, ...options });
      return { info: () => ({ sessionId: "new" }) };
    },
  } as unknown as SessionHub;
  const replies = new Map<number, Json>();
  const connection = new PhoneConnection({
    key: "k",
    hub,
    send: (message) => {
      if (typeof message["id"] === "number") replies.set(message["id"], message);
    },
    close() {},
  });
  let id = 0;
  const call = async (params: Json): Promise<Json> => {
    const mine = ++id;
    connection.receive({ jsonrpc: "2.0", id: mine, method: "_baya/fork", params });
    for (let i = 0; i < 100 && !replies.has(mine); i++) await new Promise((r) => setTimeout(r, 5));
    return replies.get(mine)!;
  };
  return { call, forks, created };
}

test("a branch holds the conversation up to the chosen agent message", async () => {
  const { call, forks, created } = phone();
  const reply = await call({
    sessionId: "s",
    messageId: "msg_1",
    messageFingerprint: `sha256:${"a".repeat(64)}`,
    messageOccurrence: 1,
  });
  expect(reply["result"]).toEqual({ session: { sessionId: "new" } });
  expect(forks).toEqual([
    { messageId: "msg_1", messageFingerprint: `sha256:${"a".repeat(64)}`, messageOccurrence: 1 },
  ]);
  expect(created).toEqual([
    { cwd: "/w", agent: "claude", title: "Add dark mode", agentSessionId: "agent-branch" },
  ]);
});

test("branching before the first reply starts the conversation over", async () => {
  const { call, forks, created } = phone();
  await call({ sessionId: "s" });
  expect(forks).toEqual([]);
  expect(created).toEqual([{ cwd: "/w", agent: "claude", title: "Add dark mode" }]);
});
