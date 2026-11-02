import { constants } from "node:fs";
import { access, readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, dirname, isAbsolute, join, parse } from "node:path";
import type { WorkspaceAgentInfo, WorkspaceDirectory } from "./types.js";
import { workspaceAgents } from "./agents.js";
import { hasDeepSeekHarness } from "./dsh_executable.js";

const MAX_DIRECTORIES = 300;

/** Resolve an executable without passing user-controlled text to a shell. */
export async function findExecutable(name: string): Promise<string | null> {
  const executableAt = async (candidate: string): Promise<string | null> => {
    try {
      await access(candidate, process.platform === "win32" ? constants.F_OK : constants.X_OK);
      return (await stat(candidate)).isFile() ? candidate : null;
    } catch {
      return null;
    }
  };
  if (isAbsolute(name)) {
    return executableAt(name);
  }
  const suffixes = process.platform === "win32" ? [".exe", ".cmd", ".bat", ""] : [""];
  for (const directory of (process.env.PATH ?? "").split(delimiter).filter(Boolean)) {
    for (const suffix of suffixes) {
      const candidate = join(directory, name + suffix);
      const found = await executableAt(candidate);
      if (found) return found;
    }
  }
  return null;
}

export async function availableAgents(
  resolveExecutable: (command: string) => Promise<string | null> = findExecutable,
  /**
   * Fallback probe for the DeepSeek Harness desktop app, which ships its ACP
   * CLI inside the install directory instead of putting `dsh` on PATH.
   */
  probeDeepSeekHarness: () => Promise<boolean> = hasDeepSeekHarness,
): Promise<WorkspaceAgentInfo[]> {
  return Promise.all(workspaceAgents.map(async ({ id, name, command, description }) => {
    const override = id === "deepseek"
      ? process.env["BAYA_DSH_BIN"]?.trim()
      : undefined;
    const onPath = await resolveExecutable(override || command) !== null;
    const available = onPath ||
      (id === "deepseek" && !override && await probeDeepSeekHarness());
    return { id, name, description, available,
      ...(!available ? { reason: `${name} is not installed on this computer.` } : {}) };
  }));
}

/** Only directories are returned; browsing never reads a file's contents. */
export async function resolveDirectory(input?: string): Promise<string> {
  if (input !== undefined && (typeof input !== "string" || input.length > 4096 || input.includes("\0"))) {
    throw new Error("Invalid folder path.");
  }
  let path = input?.trim() || homedir();
  if (path === "~") path = homedir();
  else if (/^~[/\\]/.test(path)) path = join(homedir(), path.slice(2));
  if (!isAbsolute(path)) throw new Error("Enter an absolute folder path.");
  const canonical = await realpath(path);
  if (!(await stat(canonical)).isDirectory()) throw new Error("Choose a folder, not a file.");
  return canonical;
}

export async function browseDirectory(input?: string, showHidden = false): Promise<WorkspaceDirectory> {
  const path = await resolveDirectory(input);
  const entries = await readdir(path, { withFileTypes: true });
  const directories: WorkspaceDirectory["directories"] = [];
  for (const entry of entries) {
    if (!showHidden && entry.name.startsWith(".")) continue;
    if (entry.isDirectory()) {
      directories.push({ name: entry.name, path: join(path, entry.name) });
    } else if (entry.isSymbolicLink()) {
      try {
        if ((await stat(join(path, entry.name))).isDirectory()) {
          directories.push({ name: entry.name, path: join(path, entry.name) });
        }
      } catch { /* Unreadable or dangling symlinks are not browse targets. */ }
    }
  }
  directories.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
  const parent = dirname(path);
  const home = homedir();
  return {
    path,
    parent: parent === path ? null : parent,
    home,
    roots: [...new Set([home, parse(path).root])],
    directories: directories.slice(0, MAX_DIRECTORIES),
    agents: await availableAgents(),
    truncated: directories.length > MAX_DIRECTORIES,
  };
}
