import { open, readdir, realpath, stat } from "node:fs/promises";
import { isAbsolute, relative, sep } from "node:path";
import type {
  SessionDirectory,
  SessionFileContent,
  SessionFileEntry,
} from "./types.js";

const MAX_ENTRIES = 500;
const MAX_FILE_BYTES = 256 * 1024;
const MAX_PATH_LENGTH = 4096;

function validatePath(input: string | undefined): string {
  if (
    input !== undefined &&
    (typeof input !== "string" ||
      input.length > MAX_PATH_LENGTH ||
      input.includes("\0"))
  ) {
    throw new Error("Invalid file path.");
  }
  return input?.trim() || "";
}

function isInside(root: string, candidate: string): boolean {
  const rel = relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

async function resolveRoot(cwd: string): Promise<string> {
  const root = await realpath(cwd);
  if (!(await stat(root)).isDirectory()) {
    throw new Error("The session directory is unavailable.");
  }
  return root;
}

async function resolveInside(root: string, input?: string): Promise<string> {
  const requestPath = validatePath(input);
  if (requestPath && !isAbsolute(requestPath)) {
    throw new Error("Use a path inside this session directory.");
  }
  const candidate = await realpath(requestPath || root);
  if (!isInside(root, candidate)) {
    throw new Error("That path is outside this session directory.");
  }
  return candidate;
}

function compareEntries(left: SessionFileEntry, right: SessionFileEntry): number {
  if (left.type !== right.type) return left.type === "directory" ? -1 : 1;
  return left.name.localeCompare(right.name, undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

export async function browseSessionFiles(
  cwd: string,
  input?: string,
  showHidden = false,
): Promise<SessionDirectory> {
  const root = await resolveRoot(cwd);
  const path = await resolveInside(root, input);
  if (!(await stat(path)).isDirectory()) {
    throw new Error("Choose a directory, not a file.");
  }

  const entries: SessionFileEntry[] = [];
  const directoryEntries = await readdir(path, { withFileTypes: true });
  for (const entry of directoryEntries) {
    if (!showHidden && entry.name.startsWith(".")) continue;
    if (entries.length >= MAX_ENTRIES) break;
    const entryPath = `${path}${path.endsWith(sep) ? "" : sep}${entry.name}`;
    try {
      const canonical = await realpath(entryPath);
      if (!isInside(root, canonical)) continue;
      const info = await stat(canonical);
      if (info.isDirectory()) {
        entries.push({
          name: entry.name,
          path: canonical,
          type: "directory",
          size: null,
          modified_at: Math.round(info.mtimeMs),
        });
      } else if (info.isFile()) {
        entries.push({
          name: entry.name,
          path: canonical,
          type: "file",
          size: info.size,
          modified_at: Math.round(info.mtimeMs),
        });
      }
    } catch {
      // Ignore dangling links and entries that disappear during the read.
    }
  }
  entries.sort(compareEntries);
  const parent = path === root ? null : path.slice(0, Math.max(path.lastIndexOf(sep), 0)) || null;
  return {
    root,
    path,
    parent,
    entries,
    truncated: directoryEntries.length > MAX_ENTRIES,
  };
}

export async function readSessionFile(
  cwd: string,
  input: string,
): Promise<SessionFileContent> {
  const requestPath = validatePath(input);
  if (!requestPath) throw new Error("Choose a file to open.");
  const root = await resolveRoot(cwd);
  const path = await resolveInside(root, requestPath);
  const info = await stat(path);
  if (!info.isFile()) throw new Error("Choose a file, not a directory.");

  const length = Math.min(info.size, MAX_FILE_BYTES);
  const buffer = Buffer.alloc(length);
  const handle = await open(path, "r");
  try {
    if (length > 0) await handle.read(buffer, 0, length, 0);
  } finally {
    await handle.close();
  }
  const binary = buffer.includes(0);
  return {
    name: path.slice(path.lastIndexOf(sep) + 1),
    path,
    size: info.size,
    modified_at: Math.round(info.mtimeMs),
    content: binary ? null : buffer.toString("utf8"),
    binary,
    truncated: info.size > MAX_FILE_BYTES,
  };
}
