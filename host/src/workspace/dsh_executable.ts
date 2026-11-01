import { constants } from "node:fs";
import { access, stat } from "node:fs/promises";
import { homedir, platform } from "node:os";
import { join } from "node:path";
import { findExecutable } from "./directories.js";

/**
 * The published `@deepseek-ai/dsh` CLI keeps `dsh` on PATH. The official
 * DeepSeek Harness desktop app instead ships the same ACP host inside its
 * install directory, so a user who "installed DeepSeek Harness" through the
 * desktop app has a working harness that the plain PATH probe cannot see.
 *
 * This resolves the documented env override first, then PATH, then the known
 * per-platform desktop install locations.
 */
export function deepSeekDesktopCandidates(
  env: NodeJS.ProcessEnv = process.env,
  os: NodeJS.Platform = platform(),
): string[] {
  if (os === "win32") {
    const localAppData = env["LOCALAPPDATA"]?.trim() ||
      join(homedir(), "AppData", "Local");
    return [
      join(
        localAppData,
        "Programs",
        "DeepSeek Harness",
        "resources",
        "runtime",
        "cli",
        "bin",
        "dsh.cmd",
      ),
    ];
  }
  if (os === "darwin") {
    return [
      "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh",
    ];
  }
  return [
    join(
      homedir(),
      ".local",
      "share",
      "deepseek-harness",
      "resources",
      "runtime",
      "cli",
      "bin",
      "dsh",
    ),
  ];
}

async function isRunnableFile(path: string): Promise<boolean> {
  try {
    const info = await stat(path);
    if (!info.isFile()) return false;
    // A .cmd/.bat shim on Windows is executed through cmd; F_OK is enough.
    if (platform() === "win32") return true;
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** Absolute path (or bare command) to use when spawning the harness. */
export async function resolveDeepSeekExecutable(
  env: NodeJS.ProcessEnv = process.env,
): Promise<string> {
  const override = env["BAYA_DSH_BIN"]?.trim() || env["REMOTE_PI_DSH_BIN"]?.trim();
  if (override) return override;
  if (await findExecutable("dsh")) return "dsh";
  for (const candidate of deepSeekDesktopCandidates(env)) {
    if (await isRunnableFile(candidate)) return candidate;
  }
  return "dsh";
}

/** `true` when some runnable `dsh` (PATH or desktop bundle) exists. */
export async function hasDeepSeekHarness(
  env: NodeJS.ProcessEnv = process.env,
): Promise<boolean> {
  const override =
    env["BAYA_DSH_BIN"]?.trim() || env["REMOTE_PI_DSH_BIN"]?.trim();
  if (override) return (await findExecutable(override)) !== null;
  if (await findExecutable("dsh")) return true;
  for (const candidate of deepSeekDesktopCandidates(env)) {
    if (await isRunnableFile(candidate)) return true;
  }
  return false;
}
