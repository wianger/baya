import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, test, vi } from "vitest";
import { outranks } from "../src/session/registry.ts";
import { cleanTitle } from "../src/session/titles.ts";

const FAKE_AGENT = fileURLToPath(new URL("./fixtures/fake-agent.mjs", import.meta.url));
const cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const step of cleanup.splice(0).reverse()) await step();
  delete process.env["BAYA_HOME"];
  delete process.env["BAYA_NAME_AFTER_MS"];
  vi.resetModules();
});

test("a model's answer becomes a list's title", () => {
  expect(cleanTitle("全网流量卡信息搜集推荐\n")).toBe("全网流量卡信息搜集推荐");
  expect(cleanTitle('Title: "Fix the login redirect."')).toBe("Fix the login redirect");
  expect(cleanTitle("**「北京流量卡对比」**")).toBe("北京流量卡对比");
  expect(cleanTitle("\n\n# Dark mode toggle\nmore")).toBe("Dark mode toggle");
  expect(cleanTitle("   ")).toBeNull();
});

test("a name gives way only to a stronger one", () => {
  expect(outranks("generated", "prompt")).toBe(true);
  expect(outranks("agent", "generated")).toBe(true);
  expect(outranks("generated", "agent")).toBe(false);
  expect(outranks("agent", "user")).toBe(false);
  expect(outranks("user", "user")).toBe(true);
  expect(outranks("prompt", null)).toBe(true);
});

test("the first prompt names a session, a short title replaces it, a person's name wins", async () => {
  const home = mkdtempSync(join(tmpdir(), "baya-titles-"));
  process.env["BAYA_HOME"] = home;
  process.env["BAYA_NAME_AFTER_MS"] = "50";
  writeFileSync(
    join(home, "config.json"),
    JSON.stringify({
      agents: [{ id: "fake", name: "Fake", command: [process.execPath, FAKE_AGENT] }],
    }),
  );
  vi.resetModules();
  const titles = await import("../src/session/titles.ts");
  const asked: string[] = [];
  titles.useTitleGenerator(async (text) => {
    asked.push(text);
    return "流量卡推荐";
  });
  const { SessionHub } = await import("../src/acp/hub.ts");
  const hub = new SessionHub();
  await hub.start();
  cleanup.push(() => {
    hub.stop();
    titles.useTitleGenerator(null);
    rmSync(home, { recursive: true, force: true });
  });
  const phone = {
    key: "k",
    ready: true,
    notify() {},
    ask: () => ({ id: 1, result: new Promise(() => {}) }),
    close() {},
  };
  const session = hub.create(tmpdir(), "fake");
  await session.attach(phone as never, false);
  await session.prompt(phone as never, {
    prompt: [
      { type: "text", text: "我现在需要一张流量卡，请全面深入搜集全网相关信息，给我做出推荐" },
    ],
  });
  expect(session.record.titleSource).toBe("prompt");
  await vi.waitFor(() => expect(session.title).toBe("流量卡推荐"));
  expect(session.record.titleSource).toBe("generated");
  expect(asked[0]).toContain("流量卡");

  session.rename("北京的卡");
  expect(session.title).toBe("北京的卡");
  expect(session.record.titleSource).toBe("user");
  expect(() => session.rename("  ")).toThrow(/name is required/);
});

test("a session's last activity is when its turn ended", async () => {
  const home = mkdtempSync(join(tmpdir(), "baya-activity-"));
  process.env["BAYA_HOME"] = home;
  writeFileSync(
    join(home, "config.json"),
    JSON.stringify({
      agents: [{ id: "fake", name: "Fake", command: [process.execPath, FAKE_AGENT] }],
    }),
  );
  vi.resetModules();
  const { SessionHub } = await import("../src/acp/hub.ts");
  const hub = new SessionHub();
  await hub.start();
  cleanup.push(() => {
    hub.stop();
    rmSync(home, { recursive: true, force: true });
  });
  const phone = {
    key: "k",
    ready: true,
    notify() {},
    ask: () => ({ id: 1, result: new Promise(() => {}) }),
    close() {},
  };
  const session = hub.create(tmpdir(), "fake");
  session.rename("Activity");
  await session.attach(phone as never, false);
  const before = Date.now();
  await session.prompt(phone as never, { prompt: [{ type: "text", text: "hi" }] });
  // The turn's end, after the prompt that started it.
  const ended = session.record.updatedAt;
  expect(ended).toBeGreaterThanOrEqual(before);
  await vi.waitFor(() => expect(session.working).toBe(false));
  expect(session.record.updatedAt).toBeGreaterThanOrEqual(ended);
});
