import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BAYA_HOME = process.env["BAYA_HOME"]?.trim() || join(homedir(), ".baya");

export interface BayaConfig {
  defaultAgent?: "pi" | "codex" | "deepseek";
}

function readConfig(path: string): BayaConfig | null {
  if (!existsSync(path)) return null;
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const record = value as Record<string, unknown>;
    const cfg: BayaConfig = {};
    const agent = record["defaultAgent"];
    if (agent === "pi" || agent === "codex" || agent === "deepseek") {
      cfg.defaultAgent = agent;
    }
    return cfg;
  } catch {
    return null;
  }
}

export function configPath(): string {
  return join(BAYA_HOME, "config.json");
}

export function loadConfig(): BayaConfig {
  return readConfig(configPath()) ?? {};
}

export function ensureBayaHome(): string {
  mkdirSync(BAYA_HOME, { recursive: true, mode: 0o700 });
  return BAYA_HOME;
}
