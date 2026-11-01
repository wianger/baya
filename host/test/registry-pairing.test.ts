import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";

let homes: string[] = [];

function isolatedHome(): string {
  const home = mkdtempSync(join(tmpdir(), "baya-test-"));
  homes.push(home);
  process.env["BAYA_HOME"] = home;
  vi.resetModules();
  return home;
}

afterEach(() => {
  delete process.env["BAYA_HOME"];
  vi.resetModules();
  for (const home of homes) rmSync(home, { recursive: true, force: true });
  homes = [];
});

describe("standalone session registry", () => {
  test("creates a stable record and persists user-visible changes", async () => {
    isolatedHome();
    const registry = await import("../src/session/registry.js");
    const created = registry.addSession({
      cwd: process.cwd(),
      agent: "pi",
      name: "Review",
    });
    expect(created.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(created.pi_session_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(registry.listSessions()).toEqual([created]);

    const updated = registry.updateSession(created.id, { name: "Review renamed" });
    expect(updated?.name).toBe("Review renamed");
    expect(registry.findSession(created.id.slice(0, 8))?.name).toBe("Review renamed");
    expect(registry.removeSession(created.id)).toBe(true);
    expect(registry.listSessions()).toEqual([]);
  });
});

describe("pairing token storage", () => {
  test("accepts one matching room once and rejects reuse or another room", async () => {
    isolatedHome();
    const tokens = await import("../src/pairing/token_store.js");
    const pending = tokens.issuePendingPairToken("room-a", 30_000);

    expect(tokens.consumePendingPairToken(pending.token, "room-b")).toBe("unknown");
    expect(tokens.consumePendingPairToken(pending.token, "room-a")).toBe("ok");
    expect(tokens.consumePendingPairToken(pending.token, "room-a")).toBe("consumed");
    expect(tokens.readPendingPairToken()?.consumed_at).toBeTypeOf("number");
  });
});
