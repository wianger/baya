import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";

const homes: string[] = [];
afterEach(() => {
  delete process.env["BAYA_HOME"];
  vi.resetModules();
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

test("phones get the public relay while the host dials the local one", async () => {
  const home = mkdtempSync(join(tmpdir(), "baya-config-"));
  homes.push(home);
  process.env["BAYA_HOME"] = home;
  vi.resetModules();
  const config = await import("../src/config.ts");
  expect(config.resolvePublicRelayUrl().url).toBe(config.resolveRelayUrl().url);

  writeFileSync(
    join(home, "config.json"),
    JSON.stringify({ relay: "http://127.0.0.1:3000", publicRelay: "https://relay.example" }),
  );
  expect(config.resolveRelayUrl().url).toBe("http://127.0.0.1:3000");
  expect(config.resolvePublicRelayUrl()).toEqual({
    url: "https://relay.example",
    source: "config",
  });
});
