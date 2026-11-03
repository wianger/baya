import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BAYA_HOME = process.env["BAYA_HOME"]?.trim() || join(homedir(), ".baya");

/** An ACP agent: any command that speaks ACP over stdio. */
export interface AgentDefinition {
  id: string;
  name: string;
  /** Executable and arguments, never passed through a shell. */
  command: string[];
}

export interface BayaConfig {
  agents: AgentDefinition[];
  /** Agent for sessions started without one; the first agent otherwise. */
  defaultAgent?: string;
}

export const AGENT_ID = /^[a-z0-9][a-z0-9_-]{0,31}$/u;

export function configPath(): string {
  return join(BAYA_HOME, "config.json");
}

export function parseConfig(value: unknown): BayaConfig {
  const record =
    value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const agents = Array.isArray(record["agents"])
    ? record["agents"].flatMap((entry): AgentDefinition[] => {
        if (!entry || typeof entry !== "object") return [];
        const { id, name, command } = entry as Record<string, unknown>;
        if (typeof id !== "string" || !AGENT_ID.test(id)) return [];
        if (!Array.isArray(command) || command.length === 0) return [];
        if (!command.every((part) => typeof part === "string" && part.length > 0)) return [];
        return [{ id, name: typeof name === "string" && name.trim() ? name.trim() : id, command }];
      })
    : [];
  const unique = agents.filter(
    (agent, index) => agents.findIndex((a) => a.id === agent.id) === index,
  );
  const defaultAgent = record["defaultAgent"];
  return {
    agents: unique,
    ...(typeof defaultAgent === "string" && unique.some((agent) => agent.id === defaultAgent)
      ? { defaultAgent }
      : {}),
  };
}

export function loadConfig(): BayaConfig {
  if (!existsSync(configPath())) return { agents: [] };
  try {
    return parseConfig(JSON.parse(readFileSync(configPath(), "utf8")));
  } catch {
    return { agents: [] };
  }
}

export function saveConfig(config: BayaConfig): void {
  ensureBayaHome();
  writeFileSync(configPath(), `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
}

export function defaultAgentId(config: BayaConfig = loadConfig()): string | undefined {
  return config.defaultAgent ?? config.agents[0]?.id;
}

export function ensureBayaHome(): string {
  mkdirSync(BAYA_HOME, { recursive: true, mode: 0o700 });
  return BAYA_HOME;
}
