import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import { BAYA_HOME, ensureBayaHome } from "../config.ts";

/** A Baya session: a conversation with one agent in one folder. */
export type TitleSource = "prompt" | "generated" | "agent" | "user";

const TITLE_SOURCES: readonly TitleSource[] = ["prompt", "generated", "agent", "user"];

/** Whether a title from [next] may replace one from [current]. */
export function outranks(next: TitleSource, current: TitleSource | null): boolean {
  return current === null || TITLE_SOURCES.indexOf(next) >= TITLE_SOURCES.indexOf(current);
}

export interface SessionRecord {
  /** Baya's id; the ACP `sessionId` phones see. */
  id: string;
  cwd: string;
  /** Id of an agent in the config. */
  agent: string;
  /** Set from the first prompt or by the agent; phones fall back to the folder name. */
  title: string | null;
  /**
   * Who named it, weakest first: the first prompt's line, a generated title,
   * the agent's own, a person's. A name only gives way to a stronger one.
   */
  titleSource: TitleSource | null;
  /** The agent's own session id, for `session/load` or `session/resume`. */
  agentSessionId: string | null;
  createdAt: number;
  updatedAt: number;
}

function registryPath(): string {
  return join(BAYA_HOME, "sessions.json");
}

export function transcriptPath(id: string): string {
  return join(BAYA_HOME, "sessions", `${id}.json`);
}

function normalizeCwd(input: string): string {
  try {
    return realpathSync(input);
  } catch {
    return input;
  }
}

export function folderName(cwd: string): string {
  return basename(cwd.replace(/[\\/]+$/u, "")) || cwd;
}

function parse(raw: unknown): SessionRecord[] {
  const sessions = (raw as { sessions?: unknown } | null)?.sessions;
  if (!Array.isArray(sessions)) return [];
  return sessions.flatMap((value): SessionRecord[] => {
    if (!value || typeof value !== "object") return [];
    const r = value as Record<string, unknown>;
    if (typeof r["id"] !== "string" || typeof r["cwd"] !== "string") return [];
    if (typeof r["agent"] !== "string") return [];
    return [
      {
        id: r["id"],
        cwd: r["cwd"],
        agent: r["agent"],
        title: typeof r["title"] === "string" ? r["title"] : null,
        titleSource: TITLE_SOURCES.includes(r["titleSource"] as TitleSource)
          ? (r["titleSource"] as TitleSource)
          : typeof r["title"] === "string"
            ? "prompt"
            : null,
        agentSessionId: typeof r["agentSessionId"] === "string" ? r["agentSessionId"] : null,
        createdAt: typeof r["createdAt"] === "number" ? r["createdAt"] : Date.now(),
        updatedAt: typeof r["updatedAt"] === "number" ? r["updatedAt"] : Date.now(),
      },
    ];
  });
}

export function listSessions(): SessionRecord[] {
  if (!existsSync(registryPath())) return [];
  try {
    return parse(JSON.parse(readFileSync(registryPath(), "utf8"))).toSorted(
      (a, b) => b.updatedAt - a.updatedAt,
    );
  } catch {
    return [];
  }
}

function write(sessions: SessionRecord[]): void {
  ensureBayaHome();
  const temporary = `${registryPath()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify({ version: 2, sessions }, null, 2)}\n`, {
    mode: 0o600,
  });
  renameSync(temporary, registryPath());
}

export function addSession(input: {
  cwd: string;
  agent: string;
  title?: string;
  titleSource?: TitleSource;
  agentSessionId?: string;
}): SessionRecord {
  const now = Date.now();
  const record: SessionRecord = {
    id: randomUUID(),
    cwd: normalizeCwd(input.cwd),
    agent: input.agent,
    title: input.title?.trim() || null,
    titleSource: input.title?.trim() ? (input.titleSource ?? "user") : null,
    agentSessionId: input.agentSessionId ?? null,
    createdAt: now,
    updatedAt: now,
  };
  write([...listSessions(), record]);
  mkdirSync(join(BAYA_HOME, "sessions"), { recursive: true, mode: 0o700 });
  return record;
}

export function updateSession(
  id: string,
  patch: Partial<Pick<SessionRecord, "title" | "titleSource" | "agentSessionId" | "updatedAt">>,
): SessionRecord | null {
  const sessions = listSessions();
  const record = sessions.find((entry) => entry.id === id);
  if (!record) return null;
  Object.assign(record, patch);
  write(sessions);
  return record;
}

export function removeSession(id: string): boolean {
  const sessions = listSessions();
  const next = sessions.filter((entry) => entry.id !== id);
  if (next.length === sessions.length) return false;
  write(next);
  return true;
}

/** By id, unique id prefix, or exact title. */
export function findSession(query: string): SessionRecord | null {
  const sessions = listSessions();
  const exact = sessions.find((entry) => entry.id === query);
  if (exact) return exact;
  const byPrefix = sessions.filter((entry) => entry.id.startsWith(query));
  if (byPrefix.length === 1) return byPrefix[0]!;
  const byTitle = sessions.filter((entry) => entry.title === query);
  return byTitle.length === 1 ? byTitle[0]! : null;
}
