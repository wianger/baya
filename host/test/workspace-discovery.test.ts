import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { findExecutable } from "../src/workspace/directories.js";
import { isLocalInspectorTarget } from "../src/deepseek/workspace_sync.js";

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
    const executable = join(
      directory,
      process.platform === "win32" ? "dsh.cmd" : "dsh",
    );
    writeFileSync(executable, "");
    if (process.platform !== "win32") chmodSync(executable, 0o755);

    await expect(findExecutable(executable)).resolves.toBe(executable);
  });

  test("only accepts the expected loopback inspector endpoint", () => {
    expect(
      isLocalInspectorTarget(
        "ws://127.0.0.1:9230/devtools/page/example",
        9230,
      ),
    ).toBe(true);
    expect(
      isLocalInspectorTarget(
        "ws://localhost:9230/devtools/page/example",
        9230,
      ),
    ).toBe(true);
    expect(
      isLocalInspectorTarget(
        "ws://192.168.1.10:9230/devtools/page/example",
        9230,
      ),
    ).toBe(false);
    expect(
      isLocalInspectorTarget(
        "ws://127.0.0.1:9222/devtools/page/example",
        9230,
      ),
    ).toBe(false);
  });
});
