import { randomUUID } from "node:crypto";
import {
  existsSync,
  realpathSync,
  statSync,
} from "node:fs";
import {
  open,
  readFile,
  rename,
  rm,
} from "node:fs/promises";
import { homedir } from "node:os";
import {
  basename,
  dirname,
  join,
  parse,
  resolve,
} from "node:path";
import WebSocket from "ws";

const DEFAULT_INSPECTOR_PORT = 9230;
const DEFAULT_INSPECTOR_TIMEOUT_MS = 1_000;
const DEFAULT_FILE_ATTEMPTS = 5;
const DEFAULT_RETRY_DELAY_MS = 25;

export interface WorkspaceSyncOptions {
  dshHome?: string;
  inspectorPort?: number;
  inspectorTimeoutMs?: number;
  tryInspector?: boolean;
  fileAttempts?: number;
  retryDelayMs?: number;
  now?: () => Date;
}

export interface WorkspaceSyncResult {
  via: "inspector" | "file";
  workspaceId: string;
  created: boolean;
  alreadyAttached: boolean;
}

interface WorkspaceRecord {
  path: string;
  title: string;
  sessionIds: string[];
  createdAt: string;
  updatedAt: string;
  [key: string]: unknown;
}

interface WorkspaceDocument {
  unit: {
    name: "workspace";
    version: 2;
  };
  global: {
    initialized: true;
    workspaceIds: string[];
    archivedSessionIds: string[];
    pinnedSessionIds: string[];
    pendingMutation?: unknown;
    [key: string]: unknown;
  };
  tables: {
    workspaces: Record<string, WorkspaceRecord>;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface WorkspaceDocumentMerge {
  document: WorkspaceDocument;
  workspaceId: string;
  created: boolean;
  alreadyAttached: boolean;
  changed: boolean;
}

/**
 * Register an ACP-created session in the DeepSeek Desktop workspace index.
 *
 * ACP persists the canonical session log but does not mount or mutate the
 * Desktop workspace controller. When Desktop is running, invoke its official
 * live registry through the local Inspector. When Desktop is absent, update
 * the same durable JSON store with an atomic fallback.
 */
export async function syncDeepSeekWorkspace(
  cwd: string,
  sessionId: string,
  options: WorkspaceSyncOptions = {},
): Promise<WorkspaceSyncResult> {
  if (!cwd.trim() || !sessionId.trim()) {
    throw new Error("DeepSeek workspace sync requires a directory and session id.");
  }
  if (options.tryInspector !== false) {
    const live = await trySyncViaInspector(cwd, sessionId, options);
    if (live) return live;
  }
  return await syncDeepSeekWorkspaceFile(cwd, sessionId, options);
}

/**
 * Persist one session attachment when the Desktop app is closed or its
 * Inspector is unavailable.
 */
export async function syncDeepSeekWorkspaceFile(
  cwd: string,
  sessionId: string,
  options: WorkspaceSyncOptions = {},
): Promise<WorkspaceSyncResult> {
  const canonicalCwd = canonicalDirectory(cwd);
  const path = workspaceDocumentPath(options.dshHome);
  const attempts = Math.max(1, options.fileAttempts ?? DEFAULT_FILE_ATTEMPTS);
  const retryDelayMs = Math.max(
    0,
    options.retryDelayMs ?? DEFAULT_RETRY_DELAY_MS,
  );

  if (!existsSync(path)) {
    throw new Error(`DeepSeek workspace store does not exist: ${path}`);
  }

  let lastError: Error | undefined;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const raw = await readFile(path, "utf8");
      const merged = mergeWorkspaceDocument(
        JSON.parse(raw) as unknown,
        canonicalCwd,
        sessionId,
        (options.now ?? (() => new Date()))().toISOString(),
      );
      if (!merged.changed) {
        return {
          via: "file",
          workspaceId: merged.workspaceId,
          created: false,
          alreadyAttached: true,
        };
      }

      await writeWorkspaceDocument(path, raw, merged.document);
      const verified = JSON.parse(
        await readFile(path, "utf8"),
      ) as WorkspaceDocument;
      if (
        verified.tables?.workspaces?.[merged.workspaceId]
          ?.sessionIds?.includes(sessionId)
      ) {
        return {
          via: "file",
          workspaceId: merged.workspaceId,
          created: merged.created,
          alreadyAttached: false,
        };
      }
      throw new Error("DeepSeek overwrote the workspace update concurrently.");
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt + 1 < attempts && retryDelayMs > 0) {
        await delay(retryDelayMs * (attempt + 1));
      }
    }
  }
  throw lastError ?? new Error("Could not update the DeepSeek workspace store.");
}

/**
 * Merge one session into an already parsed workspace document without
 * discarding archive, pin, default, or unknown fields.
 */
export function mergeWorkspaceDocument(
  value: unknown,
  canonicalCwd: string,
  sessionId: string,
  now: string,
): WorkspaceDocumentMerge {
  const document = validateWorkspaceDocument(value);
  const workspaces = document.tables.workspaces;
  const owner = sessionOwner(document, sessionId);
  const existing = Object.entries(workspaces).find(([, record]) =>
    samePath(record.path, canonicalCwd)
  );

  if (existing) {
    const [workspaceId, record] = existing;
    if (owner !== undefined && owner !== workspaceId) {
      throw new Error(
        `DeepSeek session ${sessionId} already belongs to workspace ${owner}.`,
      );
    }
    if (record.sessionIds.includes(sessionId)) {
      return {
        document,
        workspaceId,
        created: false,
        alreadyAttached: true,
        changed: false,
      };
    }
    record.sessionIds = [sessionId, ...record.sessionIds];
    record.updatedAt = now;
    return {
      document,
      workspaceId,
      created: false,
      alreadyAttached: false,
      changed: true,
    };
  }

  if (owner !== undefined) {
    throw new Error(
      `DeepSeek session ${sessionId} already belongs to workspace ${owner}.`,
    );
  }

  const workspaceId = randomUUID();
  const title = basename(canonicalCwd) || parse(canonicalCwd).root;
  workspaces[workspaceId] = {
    path: canonicalCwd,
    title,
    sessionIds: [sessionId],
    createdAt: now,
    updatedAt: now,
  };
  document.global.workspaceIds = [
    workspaceId,
    ...document.global.workspaceIds,
  ];
  return {
    document,
    workspaceId,
    created: true,
    alreadyAttached: false,
    changed: true,
  };
}

function sessionOwner(
  document: WorkspaceDocument,
  sessionId: string,
): string | undefined {
  return Object.entries(document.tables.workspaces).find(
    ([, record]) => record.sessionIds.includes(sessionId),
  )?.[0];
}

function validateWorkspaceDocument(value: unknown): WorkspaceDocument {
  if (!isObject(value)) {
    throw new Error("DeepSeek workspace document is not an object.");
  }
  const unit = value["unit"];
  const global = value["global"];
  const tables = value["tables"];
  if (
    !isObject(unit)
    || unit["name"] !== "workspace"
    || unit["version"] !== 2
    || !isObject(global)
    || global["initialized"] !== true
    || global["pendingMutation"] !== undefined
    || !isStringArray(global["workspaceIds"])
    || !isStringArray(global["archivedSessionIds"])
    || !isStringArray(global["pinnedSessionIds"])
    || !isObject(tables)
    || !isObject(tables["workspaces"])
  ) {
    throw new Error("DeepSeek workspace document has an unsupported shape.");
  }

  const workspaces = tables["workspaces"];
  const workspaceIds = global["workspaceIds"];
  for (const workspaceId of workspaceIds) {
    const record = workspaces[workspaceId];
    if (
      !isObject(record)
      || typeof record["path"] !== "string"
      || typeof record["title"] !== "string"
      || !isStringArray(record["sessionIds"])
      || typeof record["createdAt"] !== "string"
      || typeof record["updatedAt"] !== "string"
    ) {
      throw new Error(
        `DeepSeek workspace document has an invalid record for ${workspaceId}.`,
      );
    }
  }
  for (const workspaceId of Object.keys(workspaces)) {
    if (!workspaceIds.includes(workspaceId)) {
      throw new Error(
        `DeepSeek workspace document contains orphan ${workspaceId}.`,
      );
    }
  }
  return value as unknown as WorkspaceDocument;
}

async function trySyncViaInspector(
  cwd: string,
  sessionId: string,
  options: WorkspaceSyncOptions,
): Promise<WorkspaceSyncResult | undefined> {
  const timeoutMs = Math.max(
    100,
    options.inspectorTimeoutMs ?? DEFAULT_INSPECTOR_TIMEOUT_MS,
  );
  const port = options.inspectorPort
    ?? Number(
      process.env["BAYA_DSH_INSPECTOR_PORT"]
      || DEFAULT_INSPECTOR_PORT,
    );
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    return undefined;
  }

  try {
    const response = await fetch(`http://127.0.0.1:${port}/json`, {
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) return undefined;
    const targets = await response.json() as Array<{
      title?: unknown;
      type?: unknown;
      webSocketDebuggerUrl?: unknown;
    }>;
    const target = targets.find((entry) =>
      entry.type === "page"
      && entry.webSocketDebuggerUrl
      && String(entry.title ?? "").includes("DeepSeek Harness Host")
    );
    if (
      !target
      || !isLocalInspectorTarget(target.webSocketDebuggerUrl, port)
    ) {
      return undefined;
    }

    const socket = new WebSocket(target.webSocketDebuggerUrl);
    try {
      await waitForSocket(socket, timeoutMs);
      const value = await evaluateInspectorExpression(
        socket,
        workspaceInspectorExpression(cwd, sessionId),
        timeoutMs,
      );
      if (!isObject(value) || value["status"] !== "attached") {
        return undefined;
      }
      return {
        via: "inspector",
        workspaceId: String(value["workspaceId"] ?? ""),
        created: value["created"] === true,
        alreadyAttached: value["alreadyAttached"] === true,
      };
    } finally {
      socket.close();
      setTimeout(() => socket.terminate(), 100).unref();
    }
  } catch {
    return undefined;
  }
}

/** Only evaluate code in an inspector endpoint owned by the requested local port. */
export function isLocalInspectorTarget(
  raw: unknown,
  expectedPort: number,
): raw is string {
  if (typeof raw !== "string") return false;
  try {
    const url = new URL(raw);
    const host = url.hostname.toLowerCase();
    return url.protocol === "ws:"
      && (host === "127.0.0.1" || host === "localhost" || host === "::1" || host === "[::1]")
      && Number(url.port) === expectedPort
      && !url.username
      && !url.password;
  } catch {
    return false;
  }
}

/**
 * Attach a persisted ACP Session to its Workspace and forward the Host's
 * current Session summary to connected Desktop renderers. The latter is
 * required when the Desktop window already loaded its Session list before
 * ACP created the Session.
 */
export function workspaceInspectorExpression(
  cwd: string,
  sessionId: string,
): string {
  return `(async () => {
    const cwd = ${JSON.stringify(cwd)};
    const sessionId = ${JSON.stringify(sessionId)};
    const registries = globalThis[Symbol.for("dsh.inspector.realm-object-registries")];
    const objects = [...(registries?.values?.() ?? [])].flatMap(
      (registry) => [...(registry.retained?.values?.() ?? [])],
    );
    const root = objects.find(
      (value) => value?.constructor?.name === "Context" && value.root === value,
    );
    const registry = root?.get?.("workspaceRegistry");
    if (!registry) return { status: "unavailable" };
    let workspace = await registry.resolveByPath(cwd);
    const created = workspace === undefined;
    if (!workspace) workspace = await registry.create(cwd);
    const alreadyAttached = workspace.sessionIds.includes(sessionId);
    if (!alreadyAttached) await workspace.attachSession(sessionId);
    let announced = false;
    try {
      const sessionController = root?.get?.("sessionController");
      const listed = await sessionController?.list?.({});
      const summary = Array.isArray(listed?.items)
        ? listed.items.find((item) => item?.sessionId === sessionId)
        : undefined;
      if (summary && typeof root.emit === "function") {
        root.emit("api-session/added", summary);
        announced = true;
      }
    } catch {
      // The durable Workspace attachment remains valid if a live UI refresh
      // is temporarily unavailable.
    }
    return {
      status: "attached",
      created,
      alreadyAttached,
      announced,
      workspaceId: workspace.id,
    };
  })()`;
}

async function evaluateInspectorExpression(
  socket: WebSocket,
  expression: string,
  timeoutMs: number,
): Promise<unknown> {
  const id = 1;
  const response = new Promise<Record<string, unknown>>((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      cleanup();
      rejectPromise(new Error("DeepSeek Inspector evaluation timed out."));
    }, timeoutMs);
    const onMessage = (data: WebSocket.RawData) => {
      let message: unknown;
      try {
        message = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (!isObject(message) || message["id"] !== id) return;
      cleanup();
      resolvePromise(message);
    };
    const onError = (error: Error) => {
      cleanup();
      rejectPromise(error);
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("message", onMessage);
      socket.off("error", onError);
    };
    socket.on("message", onMessage);
    socket.on("error", onError);
    socket.send(JSON.stringify({
      id,
      method: "Runtime.evaluate",
      params: {
        expression,
        awaitPromise: true,
        returnByValue: true,
      },
    }));
  });
  const message = await response;
  const envelope = message["result"];
  if (isObject(envelope) && envelope["exceptionDetails"] !== undefined) {
    throw new Error("DeepSeek workspace Registry rejected the session attachment.");
  }
  const result = isObject(envelope) ? envelope["result"] : undefined;
  return isObject(result) ? result["value"] : undefined;
}

async function waitForSocket(
  socket: WebSocket,
  timeoutMs: number,
): Promise<void> {
  await new Promise<void>((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      cleanup();
      rejectPromise(new Error("DeepSeek Inspector connection timed out."));
    }, timeoutMs);
    const onOpen = () => {
      cleanup();
      resolvePromise();
    };
    const onError = (error: Error) => {
      cleanup();
      rejectPromise(error);
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("open", onOpen);
      socket.off("error", onError);
    };
    socket.on("open", onOpen);
    socket.on("error", onError);
  });
}

async function writeWorkspaceDocument(
  path: string,
  observedRaw: string,
  document: WorkspaceDocument,
): Promise<void> {
  const temp = join(
    dirname(path),
    `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`,
  );
  try {
    const handle = await open(temp, "wx");
    try {
      await handle.writeFile(`${JSON.stringify(document, null, 2)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (await readFile(path, "utf8") !== observedRaw) {
      throw new Error(
        "DeepSeek workspace store changed while preparing the update.",
      );
    }
    await rename(temp, path);
  } catch (error) {
    await rm(temp, { force: true }).catch(() => {});
    throw error;
  }
}

function workspaceDocumentPath(dshHome?: string): string {
  return join(
    dshHome
      ?? process.env["DSH_HOME"]?.trim()
      ?? join(homedir(), ".dsh"),
    "storages",
    "workspace.json",
  );
}

function canonicalDirectory(path: string): string {
  const canonical = realpathSync.native(resolve(path));
  if (!statSync(canonical).isDirectory()) {
    throw new Error(`DeepSeek workspace path is not a directory: ${path}`);
  }
  return canonical;
}

function samePath(left: string, right: string): boolean {
  const normalizedLeft = resolve(left);
  const normalizedRight = resolve(right);
  return process.platform === "win32"
    ? normalizedLeft.toLowerCase() === normalizedRight.toLowerCase()
    : normalizedLeft === normalizedRight;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value)
    && value.every((entry) => typeof entry === "string");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}
