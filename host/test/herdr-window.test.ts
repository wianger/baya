import { describe, expect, it } from "vitest";
import type { Json } from "../src/acp/jsonrpc.ts";
import type { HerdrCore } from "../src/herdr/core.ts";
import { HerdrWindow } from "../src/herdr/window.ts";

/** herdr-core, as far as the window backend uses it. */
function fakeCore(terminals: Json[]) {
  const calls: { method: string; params: Json }[] = [];
  const core = {
    available: async () => true,
    call: async (method: string, params: Json = {}) => {
      calls.push({ method, params });
      if (method === "terminal.list") return { terminals };
      if (method === "terminal.run") return { address: "t9" };
      if (method === "terminal.read") return { text: "line one\nline two" };
      return {};
    },
  };
  return { core: core as unknown as HerdrCore, calls };
}

describe("HerdrWindow", () => {
  it("lists the agents in the window's spaces, not other terminals", async () => {
    const { core } = fakeCore([
      {
        address: "t3",
        state: "live",
        cwd: "C:\\code\\carve",
        title: "Claude Code",
        labels: { "herdr.space": "sp1", "baya.agent": "claude", "baya.agent_session": "abc" },
        status: { app: "claude", state: "blocked" },
      },
      // A shell in the window: not an agent.
      { address: "t4", state: "live", cwd: "C:\\", labels: { "herdr.space": "sp1" } },
      // An agent no window shows.
      {
        address: "t5",
        state: "live",
        cwd: "C:\\",
        labels: {},
        status: { app: "pi", state: "idle" },
      },
    ]);
    const agents = await new HerdrWindow(core).agents();
    expect(agents).toHaveLength(1);
    expect(agents[0]).toMatchObject({
      paneId: "t3",
      agent: "claude",
      status: "blocked",
      workspaceId: "sp1",
      workspace: "carve",
      session: { kind: "id", value: "abc" },
    });
  });

  it("starts a new conversation under an id of its own, in the folder's space", async () => {
    const { core, calls } = fakeCore([]);
    const address = await new HerdrWindow(core).start("claude", "C:\\code\\carve");
    expect(address).toBe("t9");
    const run = calls.find((c) => c.method === "terminal.run")!.params;
    const labels = run["labels"] as Record<string, string>;
    expect(labels["herdr.space"]).toMatch(/^baya-[0-9a-f]{12}$/u);
    expect(run["line"]).toBe(`claude --session-id ${labels["baya.agent_session"]}`);
    expect(run["cwd"]).toBe("C:\\code\\carve");
  });

  it("resumes a conversation under its own id", async () => {
    const { core, calls } = fakeCore([]);
    await new HerdrWindow(core).start("claude", "/w", ["--resume", "s-1"]);
    const run = calls.find((c) => c.method === "terminal.run")!.params;
    expect(run["line"]).toBe("claude --resume s-1");
    expect((run["labels"] as Record<string, string>)["baya.agent_session"]).toBe("s-1");
  });

  it("types an answer key by key", async () => {
    const { core, calls } = fakeCore([]);
    await new HerdrWindow(core).sendText("t3", "1 a");
    expect(calls.at(-1)).toEqual({
      method: "terminal.keys",
      params: { terminal: "t3", keys: ["1", "space", "a"] },
    });
  });
});
