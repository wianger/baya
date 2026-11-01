import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { BAYA_HOME } from "../config.js";
import type { WorkspaceAgent } from "../workspace/types.js";

export function sessionStateKey(cwd: string, agent: WorkspaceAgent, name?: string): string {
  return createHash("sha256")
    .update(cwd)
    .update("\0")
    .update(agent)
    .update("\0")
    .update(name ?? "")
    .digest("base64url")
    .slice(0, 20);
}

export function sessionStateDirectory(): string {
  const path = join(BAYA_HOME, "sessions");
  mkdirSync(path, { recursive: true, mode: 0o700 });
  return path;
}

export function sessionStatePath(cwd: string, agent: WorkspaceAgent, name: string): string {
  return join(sessionStateDirectory(), `${sessionStateKey(cwd, agent, name)}.${agent}.json`);
}
