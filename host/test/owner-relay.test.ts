import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";

const temporaryHomes: string[] = [];

afterEach(() => {
  delete process.env["BAYA_HOME"];
  delete process.env["BAYA_RELAY"];
  delete process.env["BAYA_ALLOW_FILE_IDENTITY"];
  vi.resetModules();
  for (const home of temporaryHomes.splice(0)) {
    rmSync(home, { recursive: true, force: true });
  }
});

describe("standalone owner relay lifecycle", () => {
  test("keeps the local host alive when the relay is unavailable", async () => {
    const home = mkdtempSync(join(tmpdir(), "baya-relay-test-"));
    temporaryHomes.push(home);
    process.env["BAYA_HOME"] = home;
    process.env["BAYA_RELAY"] = "http://127.0.0.1:1";
    process.env["BAYA_ALLOW_FILE_IDENTITY"] = "1";
    vi.resetModules();

    const { OwnerRelayHost } = await import("../src/transport/owner_host.js");
    const failures: Error[] = [];
    const host = new OwnerRelayHost({
      roomId: "room",
      roomMeta: { name: "Baya", cwd: home },
      onMessage: () => {},
      onFatal: (error) => failures.push(error),
    });

    await expect(host.start()).resolves.toBeUndefined();
    expect(failures).toHaveLength(1);
    host.stop();
  });
});
