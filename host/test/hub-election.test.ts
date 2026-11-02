import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";

const homes: string[] = [];
afterEach(async () => {
  const { stopHub } = await import("../src/hub/embedded.ts");
  stopHub();
  for (const key of ["BAYA_HOME", "BAYA_RELAY", "BAYA_ALLOW_FILE_IDENTITY"])
    delete process.env[key];
  vi.resetModules();
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

test("with nobody at the local relay address, the host serves it and connects", async () => {
  const home = mkdtempSync(join(tmpdir(), "baya-election-"));
  homes.push(home);
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  process.env["BAYA_HOME"] = home;
  process.env["BAYA_RELAY"] = `http://127.0.0.1:${port}`;
  process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
  vi.resetModules();
  const { RelayHub } = await import("../src/transport/relay_hub.ts");
  const { hubRunning } = await import("../src/hub/embedded.ts");

  const hub = new RelayHub();
  const link = hub.open("room1", { name: "R", cwd: home }, { onLine: () => {} });
  await vi.waitFor(() => expect(link.isOpen()).toBe(true), { timeout: 5_000 });
  expect(hubRunning()).toBe(true);
  expect((await fetch(`http://127.0.0.1:${port}/health`)).status).toBe(200);
  link.close();
});

test("a non-local relay address is never served locally", async () => {
  const { servableLocally } = await import("../src/hub/embedded.ts");
  expect(servableLocally("https://relay.example.com")).toBeNull();
  expect(servableLocally("http://127.0.0.1:3000")).toEqual({ port: 3000 });
  expect(servableLocally("http://localhost:4000")).toEqual({ port: 4000 });
});
