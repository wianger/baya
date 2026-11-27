/**
 * The tabs in herdr's TUI that show an agent running in the herdr-app
 * window (`hc attach`): herdr-core terminal → herdr pane. Kept in
 * `~/.baya/pane-mirrors.json` across restarts, so a mirror is never taken
 * for a conversation of its own.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { BAYA_HOME } from "../config.ts";

const path = () => join(BAYA_HOME, "pane-mirrors.json");

let mirrors: Record<string, string> | null = null;

function all(): Record<string, string> {
  if (mirrors) return mirrors;
  try {
    const value: unknown = existsSync(path()) ? JSON.parse(readFileSync(path(), "utf8")) : {};
    mirrors = value && typeof value === "object" ? (value as Record<string, string>) : {};
  } catch {
    mirrors = {};
  }
  return mirrors;
}

/** Each mirror, as [terminal, herdr pane]. */
export function mirrorList(): [string, string][] {
  return Object.entries(all());
}

/** The herdr pane mirroring [terminal], if one does. */
export function mirrorFor(terminal: string): string | undefined {
  return all()[terminal];
}

export function isMirror(paneId: string): boolean {
  return Object.values(all()).includes(paneId);
}

export function setMirror(terminal: string, paneId: string | null): void {
  const map = all();
  if (paneId) map[terminal] = paneId;
  else delete map[terminal];
  mkdirSync(dirname(path()), { recursive: true, mode: 0o700 });
  writeFileSync(path(), JSON.stringify(map), { mode: 0o600 });
}
