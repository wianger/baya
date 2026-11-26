/**
 * Which Baya session each herdr pane holds, for conversations Baya ran
 * before they moved into herdr: the phone keeps knowing them by the id it
 * always had. Kept in `~/.baya/pane-aliases.json` across restarts.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { BAYA_HOME } from "../config.ts";

const path = () => join(BAYA_HOME, "pane-aliases.json");

function load(): Record<string, string> {
  try {
    if (!existsSync(path())) return {};
    const value: unknown = JSON.parse(readFileSync(path(), "utf8"));
    return value && typeof value === "object" ? (value as Record<string, string>) : {};
  } catch {
    return {};
  }
}

let aliases: Record<string, string> | null = null;

export function sessionForPane(paneId: string): string | undefined {
  aliases ??= load();
  return aliases[paneId];
}

export function setSessionForPane(paneId: string, sessionId: string | null): void {
  aliases ??= load();
  if (sessionId) aliases[paneId] = sessionId;
  else delete aliases[paneId];
  mkdirSync(dirname(path()), { recursive: true, mode: 0o700 });
  writeFileSync(path(), JSON.stringify(aliases), { mode: 0o600 });
}

/** What reopens [agent]'s conversation [sessionId] in its TUI, as arguments. */
export function resumeArgs(
  agent: string,
  sessionId: string,
  conversationExists: boolean,
): string[] | null {
  switch (agent) {
    case "claude":
      // Nothing said yet: no file to resume, so it starts under that id.
      return conversationExists ? ["--resume", sessionId] : ["--session-id", sessionId];
    case "codex":
      return ["resume", sessionId];
    case "pi":
      // Opens the folder's session with this id, or starts it.
      return ["--session-id", sessionId];
    default:
      return null;
  }
}
