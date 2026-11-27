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

describe("pairing token storage", () => {
  test("accepts a token once and rejects reuse or a wrong token", async () => {
    isolatedHome();
    const tokens = await import("../src/pairing/token_store.js");
    const pending = tokens.issuePendingPairToken(30_000);

    expect(tokens.consumePendingPairToken("wrong")).toBe("unknown");
    expect(tokens.consumePendingPairToken(pending.token)).toBe("ok");
    expect(tokens.consumePendingPairToken(pending.token)).toBe("consumed");
    expect(tokens.readPendingPairToken()?.consumed_at).toBeTypeOf("number");
  });
});
