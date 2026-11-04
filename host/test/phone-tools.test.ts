import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";

let homes: string[] = [];

async function tools() {
  const home = mkdtempSync(join(tmpdir(), "baya-phone-"));
  homes.push(home);
  process.env["BAYA_HOME"] = home;
  vi.resetModules();
  return { home, module: await import("../src/integrations/phone_tools.ts") };
}

afterEach(() => {
  delete process.env["BAYA_HOME"];
  vi.resetModules();
  for (const home of homes) rmSync(home, { recursive: true, force: true });
  homes = [];
});

test("the connected phone is remembered and forgotten", async () => {
  const { module } = await tools();
  expect(module.connectedPhone()).toBeNull();
  module.rememberPhone("100.80.1.2:41234");
  expect(module.connectedPhone()).toBe("100.80.1.2:41234");
  module.rememberPhone(null);
  expect(module.connectedPhone()).toBeNull();
});

test("sessions get the phone tools only with a phone and the tools installed", async () => {
  const { home, module } = await tools();
  expect(await module.phoneMcpServers()).toEqual([]);
  module.rememberPhone("100.80.1.2:41234");
  // Connected, but mobile-mcp not installed yet.
  expect(await module.phoneMcpServers()).toEqual([]);
  const lib = join(home, "tools", "mobile-mcp", "node_modules", "@mobilenext", "mobile-mcp", "lib");
  mkdirSync(lib, { recursive: true });
  writeFileSync(join(lib, "index.js"), "");
  expect(module.phoneToolsReady()).toBe(true);
  const servers = (await module.phoneMcpServers()) as Array<{
    name: string;
    args: string[];
    env: Array<{ name: string; value: string }>;
  }>;
  // Without node or adb on this machine there is nothing to run.
  if (servers.length === 0) return;
  expect(servers[0]!.name).toBe("phone");
  expect(servers[0]!.args).toEqual([join(lib, "index.js")]);
  expect(servers[0]!.env).toContainEqual({ name: "MOBILEMCP_DISABLE_TELEMETRY", value: "1" });
});
