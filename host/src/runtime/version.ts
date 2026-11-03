import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Set by the single-executable build, which has no package.json beside it. */
declare const __BAYA_VERSION__: string | undefined;

let cached: string | null = null;

export function packageVersion(): string {
  if (cached) return cached;
  if (typeof __BAYA_VERSION__ === "string") {
    cached = __BAYA_VERSION__;
    return cached;
  }
  try {
    // This module lives in both src/runtime and dist/runtime. In either
    // layout the package manifest is two directories above it.
    const path = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "package.json");
    const value = JSON.parse(readFileSync(path, "utf8")) as { version?: unknown };
    cached = typeof value.version === "string" ? value.version : "2.0.0";
  } catch {
    cached = "2.0.0";
  }
  return cached;
}
