import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_RELAY_URL = "https://wiang-1.tail171f4a.ts.net";
export const BAYA_HOME = process.env["BAYA_HOME"]?.trim() || join(homedir(), ".baya");

export interface BayaConfig {
  relay?: string;
  defaultAgent?: "pi" | "codex" | "deepseek";
}

export interface ResolvedRelay {
  url: string;
  source: "env" | "config" | "default";
}

function readConfig(path: string): BayaConfig | null {
  if (!existsSync(path)) return null;
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const record = value as Record<string, unknown>;
    const cfg: BayaConfig = {};
    if (typeof record["relay"] === "string" && record["relay"].trim()) {
      cfg.relay = record["relay"].trim();
    }
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

export function saveConfig(patch: Partial<BayaConfig>): BayaConfig {
  const next = { ...loadConfig(), ...patch };
  mkdirSync(BAYA_HOME, { recursive: true, mode: 0o700 });
  writeFileSync(configPath(), JSON.stringify(next, null, 2) + "\n", { mode: 0o600 });
  return next;
}

export function resolveRelayUrl(): ResolvedRelay {
  const override = process.env["BAYA_RELAY"]?.trim();
  if (override) return { url: override, source: "env" };

  const current = loadConfig().relay;
  if (current) return { url: current, source: "config" };

  return { url: DEFAULT_RELAY_URL, source: "default" };
}

export function toWebSocketUrl(url: string): string {
  const parsed = new URL(url);
  if (parsed.protocol === "http:") parsed.protocol = "ws:";
  else if (parsed.protocol === "https:") parsed.protocol = "wss:";
  else if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
    throw new Error("Relay URL must use http, https, ws, or wss.");
  }
  parsed.hash = "";
  parsed.search = "";
  return parsed.toString().replace(/\/$/, "");
}

export function validateRelayUrl(input: string): string {
  const trimmed = input.trim();
  if (!trimmed) throw new Error("Relay URL cannot be empty.");
  const parsed = new URL(trimmed);
  if (!["http:", "https:", "ws:", "wss:"].includes(parsed.protocol)) {
    throw new Error("Relay URL must use http, https, ws, or wss.");
  }
  if (!parsed.hostname || parsed.username || parsed.password) {
    throw new Error("Relay URL must have a host and no embedded credentials.");
  }
  parsed.protocol = parsed.protocol === "ws:" ? "http:" : parsed.protocol === "wss:" ? "https:" : parsed.protocol;
  parsed.hash = "";
  parsed.search = "";
  return parsed.toString().replace(/\/$/, "");
}

export function ensureBayaHome(): string {
  mkdirSync(BAYA_HOME, { recursive: true, mode: 0o700 });
  return BAYA_HOME;
}
