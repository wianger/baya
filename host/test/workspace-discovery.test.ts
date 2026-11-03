import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { findExecutable } from "../src/workspace/directories.ts";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("workspace discovery", () => {
  test("resolves an absolute executable override directly", async () => {
    const directory = mkdtempSync(join(tmpdir(), "baya-discovery-"));
    temporaryDirectories.push(directory);
    const executable = join(directory, process.platform === "win32" ? "dsh.cmd" : "dsh");
    writeFileSync(executable, "");
    if (process.platform !== "win32") chmodSync(executable, 0o755);

    await expect(findExecutable(executable)).resolves.toBe(executable);
  });
});
