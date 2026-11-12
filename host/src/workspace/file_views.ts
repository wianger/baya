/**
 * Ways to look into files the phone cannot show itself: the entries of an
 * archive (zip, tar, tar.gz), one entry taken out, and office documents
 * turned into PDF by LibreOffice when the computer has it.
 */
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, extname, join } from "node:path";
import { promisify } from "node:util";
import { gunzipSync, inflateRawSync } from "node:zlib";
import { RpcError } from "../acp/jsonrpc.ts";
import { findExecutable } from "./directories.ts";
import { bayaFolder, inside, safeFileName } from "./transfer.ts";

const run = promisify(execFile);
const MAX_ARCHIVE_BYTES = 200 * 1024 * 1024;
const MAX_ENTRY_BYTES = 100 * 1024 * 1024;
const MAX_ENTRIES = 5000;

interface ArchiveEntry {
  name: string;
  size: number;
  directory: boolean;
}

interface Located extends ArchiveEntry {
  read: () => Buffer;
}

function kindOf(path: string): "zip" | "tar" | "tgz" | null {
  const lower = path.toLowerCase();
  if (/\.(zip|jar|apk|aar|whl|epub|docx|xlsx|pptx|odt|ods|odp)$/u.test(lower)) return "zip";
  if (lower.endsWith(".tar")) return "tar";
  if (lower.endsWith(".tar.gz") || lower.endsWith(".tgz")) return "tgz";
  return null;
}

/** Zip entries from the central directory; stored and deflated data. */
function zipEntries(data: Buffer): Located[] {
  const from = Math.max(0, data.length - 65_557);
  let end = -1;
  for (let i = data.length - 22; i >= from; i--) {
    if (data.readUInt32LE(i) === 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new Error("This is not a zip archive.");
  const count = data.readUInt16LE(end + 10);
  let at = data.readUInt32LE(end + 16);
  if (at === 0xffffffff) throw new Error("Zip64 archives can't be opened yet.");
  const entries: Located[] = [];
  for (let n = 0; n < count && n < MAX_ENTRIES; n++) {
    if (data.readUInt32LE(at) !== 0x02014b50) throw new Error("The zip archive is damaged.");
    const flags = data.readUInt16LE(at + 8);
    const method = data.readUInt16LE(at + 10);
    const packed = data.readUInt32LE(at + 20);
    const size = data.readUInt32LE(at + 24);
    const nameLength = data.readUInt16LE(at + 28);
    const extraLength = data.readUInt16LE(at + 30);
    const commentLength = data.readUInt16LE(at + 32);
    const local = data.readUInt32LE(at + 42);
    const raw = data.subarray(at + 46, at + 46 + nameLength);
    const name = raw.toString(flags & 0x800 ? "utf8" : "latin1");
    entries.push({
      name,
      size,
      directory: name.endsWith("/"),
      read: () => {
        if (flags & 0x1) throw new Error("This entry is encrypted.");
        const start = local + 30 + data.readUInt16LE(local + 26) + data.readUInt16LE(local + 28);
        const body = data.subarray(start, start + packed);
        if (method === 0) return Buffer.from(body);
        if (method === 8) return inflateRawSync(body, { maxOutputLength: MAX_ENTRY_BYTES });
        throw new Error("This entry is compressed in a way Baya can't read.");
      },
    });
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

function tarEntries(data: Buffer): Located[] {
  const entries: Located[] = [];
  let at = 0;
  let longName: string | null = null;
  while (at + 512 <= data.length && entries.length < MAX_ENTRIES) {
    const header = data.subarray(at, at + 512);
    if (header.every((byte) => byte === 0)) break;
    const field = (start: number, length: number) =>
      header
        .subarray(start, start + length)
        .toString("utf8")
        .replace(/\0.*$/su, "");
    const size = Number.parseInt(field(124, 12).trim() || "0", 8);
    const type = field(156, 1);
    const prefix = field(345, 155);
    const body = at + 512;
    at = body + Math.ceil(size / 512) * 512;
    if (type === "L") {
      longName = data
        .subarray(body, body + size)
        .toString("utf8")
        .replace(/\0.*$/su, "");
      continue;
    }
    if (type === "x" || type === "g") continue;
    const name = longName ?? (prefix ? `${prefix}/${field(0, 100)}` : field(0, 100));
    longName = null;
    const directory = type === "5" || name.endsWith("/");
    entries.push({
      name: directory && !name.endsWith("/") ? `${name}/` : name,
      size,
      directory,
      read: () => Buffer.from(data.subarray(body, body + size)),
    });
  }
  return entries;
}

async function entriesOf(path: string): Promise<Located[]> {
  const kind = kindOf(path);
  if (!kind) throw new Error("This is not an archive Baya can open.");
  if ((await stat(path)).size > MAX_ARCHIVE_BYTES) throw new Error("This archive is too large.");
  const data = await readFile(path);
  if (kind === "zip") return zipEntries(data);
  return tarEntries(
    kind === "tgz" ? gunzipSync(data, { maxOutputLength: MAX_ARCHIVE_BYTES }) : data,
  );
}

/** The entries of the archive at [input], a file in the session. */
export async function listArchive(
  cwd: string,
  input: string,
): Promise<{ entries: ArchiveEntry[]; truncated: boolean }> {
  const path = await inside(cwd, input);
  const entries = await entriesOf(path);
  return {
    entries: entries.map(({ name, size, directory }) => ({ name, size, directory })),
    truncated: entries.length >= MAX_ENTRIES,
  };
}

/** A folder per file version below `.baya/<kind>`, so a changed file is new. */
async function cacheFolder(root: string, kind: string, path: string): Promise<string> {
  const info = await stat(path);
  const key = createHash("sha256")
    .update(`${path}\0${info.size}\0${info.mtimeMs}`)
    .digest("hex")
    .slice(0, 12);
  return bayaFolder(root, kind, key);
}

/** Takes entry [name] out of the archive at [input]; returns where it is. */
export async function extractEntry(
  cwd: string,
  input: string,
  name: string,
): Promise<{ path: string; name: string; size: number }> {
  const root = await inside(cwd, undefined);
  const path = await inside(root, input);
  const entry = (await entriesOf(path)).find((e) => e.name === name && !e.directory);
  if (!entry) throw new Error("That entry is not in the archive.");
  if (entry.size > MAX_ENTRY_BYTES) throw new Error("That entry is too large.");
  const parts = name.split(/[\\/]/u).filter((part) => part && part !== "." && part !== "..");
  const target = join(
    await cacheFolder(root, "extracted", path),
    ...parts.map((part) => safeFileName(part)),
  );
  await mkdir(dirname(target), { recursive: true });
  const bytes = entry.read();
  await writeFile(target, bytes);
  return { path: target, name: basename(target), size: bytes.length };
}

const OFFICE = /\.(docx?|xlsx?|pptx?|odt|ods|odp|rtf)$/iu;

/** LibreOffice's command on this computer, or null. */
async function officeConverter(): Promise<string | null> {
  for (const name of ["soffice", "libreoffice"]) {
    const found = await findExecutable(name);
    if (found) return found;
  }
  const candidates =
    process.platform === "win32"
      ? [
          join(
            process.env["ProgramFiles"] ?? "C:\\Program Files",
            "LibreOffice",
            "program",
            "soffice.exe",
          ),
          join(
            process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)",
            "LibreOffice",
            "program",
            "soffice.exe",
          ),
        ]
      : process.platform === "darwin"
        ? [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            join(homedir(), "Applications/LibreOffice.app/Contents/MacOS/soffice"),
          ]
        : [];
  for (const candidate of candidates) {
    const found = await findExecutable(candidate);
    if (found) return found;
  }
  return null;
}

/** The office document at [input] as a PDF beside it in `.baya/converted`. */
export async function convertToPdf(
  cwd: string,
  input: string,
): Promise<{ path: string; name: string }> {
  const root = await inside(cwd, undefined);
  const path = await inside(root, input);
  if (!OFFICE.test(path)) throw new Error("Only office documents turn into PDF.");
  const office = await officeConverter();
  if (!office) {
    throw new RpcError(-32000, "Install LibreOffice on the computer to preview office documents.", {
      reason: "no_office",
    });
  }
  const folder = await cacheFolder(root, "converted", path);
  const name = `${basename(path, extname(path))}.pdf`;
  const target = join(folder, name);
  try {
    await stat(target);
    return { path: target, name };
  } catch {
    // Not converted yet.
  }
  await run(
    office,
    ["--headless", "--norestore", "--convert-to", "pdf", "--outdir", folder, path],
    {
      timeout: 120_000,
      windowsHide: true,
    },
  );
  await stat(target);
  return { path: target, name };
}
