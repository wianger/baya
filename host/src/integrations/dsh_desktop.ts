/**
 * DeepSeek Harness's desktop app lists only sessions recorded in one of its
 * workspaces (`$DSH_HOME/storages/workspace.json`); sessions started over
 * ACP are stored alongside but never recorded. Baya records them, creating
 * the folder's workspace when there is none.
 *
 * The desktop app keeps that file in memory and overwrites it on its next
 * change, so Baya writes only while the app is closed and otherwise retries
 * until it is.
 */
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { type AgentDefinition, BAYA_HOME } from "../config.ts";

const RETRY_MS = 30_000;

interface Pending {
  dshHome: string;
  sessionId: string;
  cwd: string;
}

interface WorkspaceRecord {
  path: string;
  title: string;
  sessionIds: string[];
  createdAt: string;
  updatedAt: string;
  [key: string]: unknown;
}

interface WorkspaceFile {
  unit?: { name?: string; version?: number };
  global?: { workspaceIds?: string[]; [key: string]: unknown };
  tables?: { workspaces?: Record<string, WorkspaceRecord> };
  [key: string]: unknown;
}

/** Whether [definition] runs DeepSeek Harness. */
export function isDsh(definition: AgentDefinition): boolean {
  const executable = definition.command[0] ?? "";
  return /^dsh(\.cmd|\.exe|\.ps1)?$/iu.test(basename(executable.replace(/\\/gu, "/")));
}

function desktopRunning(): boolean {
  try {
    if (process.platform === "win32") {
      return execFileSync("tasklist", ["/FI", "IMAGENAME eq DeepSeek Harness.exe", "/NH"], {
        encoding: "utf8",
      }).includes("DeepSeek Harness");
    }
    execFileSync("pgrep", ["-f", "DeepSeek Harness"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export class DshDesktop {
  private timer: NodeJS.Timeout | null = null;

  private readonly pendingFile: string;
  private readonly isRunning: () => boolean;

  constructor(pendingFile: string, isRunning: () => boolean = desktopRunning) {
    this.pendingFile = pendingFile;
    this.isRunning = isRunning;
  }

  /** Records [sessionId] in the desktop app's workspace for [cwd]. */
  register(definition: AgentDefinition, sessionId: string, cwd: string): void {
    const dshHome =
      definition.env?.["DSH_HOME"] ?? process.env["DSH_HOME"] ?? join(homedir(), ".dsh");
    const pending = this.load();
    if (!pending.some((item) => item.sessionId === sessionId && item.dshHome === dshHome)) {
      pending.push({ dshHome, sessionId, cwd });
      this.save(pending);
    }
    this.flush();
  }

  /** Writes what is pending if the desktop app is closed; else retries later. */
  flush(): void {
    const pending = this.load();
    if (pending.length === 0) return this.stopRetrying();
    if (this.isRunning()) return this.retry();
    for (const [dshHome, items] of groupBy(pending, (item) => item.dshHome)) {
      try {
        record(dshHome, items);
      } catch (error) {
        process.stderr.write(`[baya] DeepSeek desktop: ${(error as Error).message}\n`);
      }
    }
    // Written, or impossible to write (format we do not know): either way
    // there is nothing left to retry.
    this.save([]);
    this.stopRetrying();
  }

  private retry(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.flush(), RETRY_MS);
    this.timer.unref();
  }

  private stopRetrying(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private load(): Pending[] {
    try {
      const value = JSON.parse(readFileSync(this.pendingFile, "utf8")) as unknown;
      return Array.isArray(value) ? (value as Pending[]) : [];
    } catch {
      return [];
    }
  }

  private save(pending: Pending[]): void {
    mkdirSync(dirname(this.pendingFile), { recursive: true });
    writeFileSync(this.pendingFile, `${JSON.stringify(pending, null, 2)}\n`, { mode: 0o600 });
  }
}

function groupBy<T>(items: T[], key: (item: T) => string): Map<string, T[]> {
  const groups = new Map<string, T[]>();
  for (const item of items) groups.set(key(item), [...(groups.get(key(item)) ?? []), item]);
  return groups;
}

function canonical(path: string): string {
  let resolved = path;
  try {
    resolved = realpathSync.native(path);
  } catch {}
  resolved = resolved.replace(/[\\/]+$/u, "");
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

/** Adds [items] to the workspace file under [dshHome]. */
function record(dshHome: string, items: Pending[]): void {
  const file = join(dshHome, "storages", "workspace.json");
  // No file means the desktop app never ran with this home: nothing lists it.
  if (!existsSync(file)) return;
  const text = readFileSync(file, "utf8");
  const data = JSON.parse(text) as WorkspaceFile;
  if (data.unit?.name !== "workspace" || data.unit.version !== 2) {
    throw new Error(`unknown workspace file format in ${file}; left unchanged`);
  }
  const workspaces = (data.tables ??= {}).workspaces ?? {};
  data.tables.workspaces = workspaces;
  const global = (data.global ??= {});
  const order = (global.workspaceIds ??= []);
  const now = new Date().toISOString();
  let changed = false;
  for (const { sessionId, cwd } of items) {
    let path = cwd;
    try {
      path = realpathSync.native(cwd);
    } catch {}
    const existing = Object.values(workspaces).find(
      (workspace) => canonical(workspace.path) === canonical(path),
    );
    if (existing) {
      if (existing.sessionIds.includes(sessionId)) continue;
      existing.sessionIds = [sessionId, ...existing.sessionIds];
      existing.updatedAt = now;
    } else {
      const id = randomUUID();
      workspaces[id] = {
        path,
        title: basename(path) || path,
        sessionIds: [sessionId],
        createdAt: now,
        updatedAt: now,
      };
      order.push(id);
    }
    changed = true;
  }
  if (!changed) return;
  const backup = `${file}.baya-backup`;
  if (!existsSync(backup)) writeFileSync(backup, text);
  const temporary = `${file}.baya-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(data, null, 2)}\n`);
  renameSync(temporary, file);
}

/** The host's one registry; its queue survives restarts. */
export const dshDesktop = new DshDesktop(join(BAYA_HOME, "runtime", "dsh-desktop-pending.json"));
