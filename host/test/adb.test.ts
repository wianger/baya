import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { adbConnect, adbPair, findAdb } from "../src/integrations/adb.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

test.skipIf(process.platform === "win32")("adb is found in an Android SDK", async () => {
  const sdk = mkdtempSync(join(tmpdir(), "baya-sdk-"));
  dirs.push(sdk);
  mkdirSync(join(sdk, "platform-tools"));
  const adb = join(sdk, "platform-tools", "adb");
  writeFileSync(adb, "#!/bin/sh\n");
  chmodSync(adb, 0o755);
  const found = await findAdb({ ANDROID_HOME: sdk, PATH: "" });
  // A real adb on this machine's PATH or Scoop wins; otherwise the SDK's.
  expect(found === adb || (found !== null && /adb(\.exe)?$/u.test(found))).toBe(true);
});

test("pairing and connecting check what they are given", async () => {
  await expect(adbPair("100.64.0.2:37000", "12")).rejects.toThrow(/six digits/);
  await expect(adbPair("rm -rf /", "123456")).rejects.toThrow(/ip:port/);
  await expect(adbConnect("100.64.0.2")).rejects.toThrow(/ip:port/);
});
