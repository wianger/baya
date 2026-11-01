import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

let cached: string | null = null;

export function packageVersion(): string {
  if (cached) return cached;
  try {
    const path = join(dirname(fileURLToPath(import.meta.url)), "..", "package.json");
    const value = JSON.parse(readFileSync(path, "utf8")) as { version?: unknown };
    cached = typeof value.version === "string" ? value.version : "2.0.0";
  } catch {
    cached = "2.0.0";
  }
  return cached;
}
