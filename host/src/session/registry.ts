import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { realpathSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { BAYA_HOME, ensureBayaHome } from "../config.js";
import type { WorkspaceAgent } from "../workspace/types.js";

export interface BayaSessionRecord {
  id: string;
  name: string;
  cwd: string;
  agent: WorkspaceAgent;
  created_at: number;
  updated_at: number;
  pi_session_id?: string;
}

interface RegistryDocument {
  version: 1;
  sessions: BayaSessionRecord[];
}

let mutation: Promise<void> = Promise.resolve();

export function registryPath(): string {
  return join(BAYA_HOME, "sessions.json");
}

export function normalizeCwd(input: string): string {
  try {
    return realpathSync(input);
  } catch {
    return input;
  }
}

export function defaultSessionName(cwd: string, agent: WorkspaceAgent): string {
  const folder = basename(normalizeCwd(cwd)) || "workspace";
  if (agent === "pi") return folder;
  if (agent === "codex") return `Codex · ${folder}`;
  if (agent === "deepseek") return `DeepSeek · ${folder}`;
  return `${agent} · ${folder}`;
}

export function sessionIdFor(cwd: string, agent: WorkspaceAgent, name?: string): string {
  const logicalName = name?.trim() || defaultSessionName(cwd, agent);
  return createHash("sha256")
    .update(normalizeCwd(cwd))
    .update("\0")
    .update(agent)
    .update("\0")
    .update(logicalName)
    .digest("base64url")
    .slice(0, 20);
}

function parseRegistry(raw: unknown): RegistryDocument {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { version: 1, sessions: [] };
  }
  const sessions = (raw as { sessions?: unknown }).sessions;
  if (!Array.isArray(sessions)) return { version: 1, sessions: [] };
  return {
    version: 1,
    sessions: sessions.flatMap((value): BayaSessionRecord[] => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return [];
      const record = value as Record<string, unknown>;
      if (
        typeof record["id"] !== "string" ||
        typeof record["name"] !== "string" ||
        typeof record["cwd"] !== "string" ||
        !["pi", "codex", "deepseek"].includes(String(record["agent"]))
      ) return [];
      return [{
        id: record["id"],
        name: record["name"],
        cwd: record["cwd"],
        agent: record["agent"] as WorkspaceAgent,
        created_at: typeof record["created_at"] === "number" ? record["created_at"] : Date.now(),
        updated_at: typeof record["updated_at"] === "number" ? record["updated_at"] : Date.now(),
        ...(typeof record["pi_session_id"] === "string"
          ? { pi_session_id: record["pi_session_id"] }
          : {}),
      }];
    }),
  };
}

export function readRegistry(): RegistryDocument {
  const path = registryPath();
  if (!existsSync(path)) return { version: 1, sessions: [] };
  try {
    return parseRegistry(JSON.parse(readFileSync(path, "utf8")) as unknown);
  } catch {
    return { version: 1, sessions: [] };
  }
}

export function listSessions(): BayaSessionRecord[] {
  return readRegistry().sessions.toSorted((left, right) => right.updated_at - left.updated_at);
}

function writeRegistry(document: RegistryDocument): void {
  ensureBayaHome();
  mkdirSync(dirname(registryPath()), { recursive: true, mode: 0o700 });
  writeFileSync(registryPath(), JSON.stringify(document, null, 2) + "\n", { mode: 0o600 });
}

export function addSession(input: {
  cwd: string;
  agent: WorkspaceAgent;
  name?: string;
  id?: string;
}): BayaSessionRecord {
  const cwd = normalizeCwd(input.cwd);
  const name = input.name?.trim() || defaultSessionName(cwd, input.agent);
  const id = input.id || randomUUID();
  const document = readRegistry();
  const existing = document.sessions.find((entry) => entry.id === id);
  if (existing) return existing;
  const now = Date.now();
  const record: BayaSessionRecord = {
    id,
    name,
    cwd,
    agent: input.agent,
    created_at: now,
    updated_at: now,
    ...(input.agent === "pi" ? { pi_session_id: randomUUID() } : {}),
  };
  document.sessions.push(record);
  writeRegistry(document);
  return record;
}

export function updateSession(
  id: string,
  patch: Partial<Pick<BayaSessionRecord, "name" | "pi_session_id">>,
): BayaSessionRecord | null {
  const document = readRegistry();
  const record = document.sessions.find((entry) => entry.id === id);
  if (!record) return null;
  Object.assign(record, patch, { updated_at: Date.now() });
  writeRegistry(document);
  return record;
}

export function removeSession(id: string): boolean {
  const document = readRegistry();
  const next = document.sessions.filter((entry) => entry.id !== id);
  if (next.length === document.sessions.length) return false;
  document.sessions = next;
  writeRegistry(document);
  return true;
}

export function findSession(idOrPrefix: string): BayaSessionRecord | null {
  const matches = listSessions().filter((entry) =>
    entry.id === idOrPrefix || entry.id.startsWith(idOrPrefix)
  );
  return matches.length === 1 ? matches[0]! : null;
}
