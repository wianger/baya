import { randomUUID } from "node:crypto";
import {
  type FileHandle,
  mkdir,
  open,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { extname, isAbsolute, join, relative, sep } from "node:path";

/** Largest file either way; the phone keeps a download in memory to save it. */
const MAX_TRANSFER_BYTES = 100 * 1024 * 1024;
/** Largest piece of one `_baya/upload_chunk` or `_baya/download` (raw bytes). */
const MAX_CHUNK_BYTES = 1024 * 1024;

class TransferError extends Error {}

interface Upload {
  owner: string;
  handle: FileHandle;
  part: string;
  dir: string;
  name: string;
  size: number;
  received: number;
}

function isInside(root: string, candidate: string): boolean {
  const rel = relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

/** The real path of [input] (or of [root]), refused outside [root]. */
export async function inside(root: string, input: string | undefined): Promise<string> {
  if (input !== undefined && (!isAbsolute(input) || input.includes("\0"))) {
    throw new TransferError("Use a path inside this session directory.");
  }
  const candidate = await realpath(input ?? root);
  if (!isInside(root, candidate)) {
    throw new TransferError("That path is outside this session directory.");
  }
  return candidate;
}

/**
 * `<root>/.baya/<parts>`, created, for what Baya keeps in a session's folder
 * (uploads, extracted and converted files); `.baya` stays out of git.
 */
export async function bayaFolder(root: string, ...parts: string[]): Promise<string> {
  const dir = join(root, ".baya", ...parts);
  await mkdir(dir, { recursive: true });
  await writeFile(join(root, ".baya", ".gitignore"), "*\n", { flag: "wx" }).catch(() => {});
  return dir;
}

const RESERVED = /^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$/i;

/** A file name safe on Windows, macOS and Linux, from whatever the phone sent. */
export function safeFileName(input: string): string {
  const base = input.split(/[\\/]/).pop() ?? "";
  let name = base
    .replace(/[<>:"|?*]/g, "_")
    .replace(/\p{Cc}/gu, "_")
    .replace(/[. ]+$/, "")
    .trim();
  if (!name || RESERVED.test(name)) name = `file${name ? `-${name}` : ""}`;
  if (name.length > 180) {
    const ext = extname(name).slice(0, 20);
    name = name.slice(0, 180 - ext.length) + ext;
  }
  return name;
}

/** `name`, or `name (2).ext`… — whichever is free in [dir]. */
async function freeName(dir: string, name: string): Promise<string> {
  const ext = extname(name);
  const stem = name.slice(0, name.length - ext.length);
  for (let n = 1; n < 1000; n++) {
    const candidate = n === 1 ? name : `${stem} (${n})${ext}`;
    try {
      await stat(join(dir, candidate));
    } catch {
      return candidate;
    }
  }
  throw new TransferError("Too many files with that name.");
}

/**
 * Files sent from the phone, written to a hidden part file beside their
 * destination and renamed into place once every byte arrived. Each belongs
 * to the phone connection that began it.
 */
export class Uploads {
  private readonly open = new Map<string, Upload>();

  async begin(
    owner: string,
    cwd: string,
    request: { name: string; size: number; dir?: string | undefined },
  ): Promise<{ uploadId: string; dir: string }> {
    const { size } = request;
    if (!Number.isSafeInteger(size) || size < 0)
      throw new TransferError("A file size is required.");
    if (size > MAX_TRANSFER_BYTES) {
      throw new TransferError(`Files over ${MAX_TRANSFER_BYTES / 1024 / 1024} MB can't be sent.`);
    }
    const root = await realpath(cwd);
    let dir: string;
    if (request.dir === undefined) {
      dir = await inside(root, await bayaFolder(root, "uploads"));
    } else {
      dir = await inside(root, request.dir);
    }
    if (!(await stat(dir)).isDirectory())
      throw new TransferError("Choose a folder to upload into.");
    const uploadId = randomUUID();
    const part = join(dir, `.baya-upload-${uploadId}.part`);
    const handle = await open(part, "wx");
    this.open.set(uploadId, {
      owner,
      handle,
      part,
      dir,
      name: safeFileName(request.name),
      size,
      received: 0,
    });
    return { uploadId, dir };
  }

  async chunk(
    owner: string,
    uploadId: string,
    offset: number,
    data: string,
  ): Promise<{ received: number }> {
    const upload = this.get(owner, uploadId);
    if (offset !== upload.received) {
      throw new TransferError(`Expected bytes from ${upload.received}, got ${offset}.`);
    }
    const bytes = Buffer.from(data, "base64");
    if (bytes.length > MAX_CHUNK_BYTES) throw new TransferError("That piece is too large.");
    if (upload.received + bytes.length > upload.size) {
      await this.cancel(owner, uploadId);
      throw new TransferError("The file is larger than announced.");
    }
    await upload.handle.write(bytes, 0, bytes.length, upload.received);
    upload.received += bytes.length;
    return { received: upload.received };
  }

  async finish(
    owner: string,
    uploadId: string,
  ): Promise<{ name: string; path: string; size: number }> {
    const upload = this.get(owner, uploadId);
    if (upload.received !== upload.size) {
      throw new TransferError(`Only ${upload.received} of ${upload.size} bytes arrived.`);
    }
    this.open.delete(uploadId);
    await upload.handle.close();
    try {
      const name = await freeName(upload.dir, upload.name);
      const path = join(upload.dir, name);
      await rename(upload.part, path);
      return { name, path, size: upload.size };
    } catch (error) {
      await rm(upload.part, { force: true });
      throw error;
    }
  }

  async cancel(owner: string, uploadId: string): Promise<void> {
    const upload = this.open.get(uploadId);
    if (!upload || upload.owner !== owner) return;
    this.open.delete(uploadId);
    await upload.handle.close().catch(() => {});
    await rm(upload.part, { force: true });
  }

  /** The phone went away: drop what it left half sent. */
  async drop(owner: string): Promise<void> {
    const ids = [...this.open].filter(([, upload]) => upload.owner === owner).map(([id]) => id);
    await Promise.all(ids.map((id) => this.cancel(owner, id)));
  }

  private get(owner: string, uploadId: string): Upload {
    const upload = this.open.get(uploadId);
    if (!upload || upload.owner !== owner)
      throw new TransferError("That upload is no longer open.");
    return upload;
  }
}

export const uploads = new Uploads();

/** One piece of a session file for the phone to save. */
export async function downloadChunk(
  cwd: string,
  input: string,
  offset: number,
  length: number,
): Promise<{ name: string; size: number; offset: number; data: string; eof: boolean }> {
  const root = await realpath(cwd);
  const path = await inside(root, input);
  const info = await stat(path);
  if (!info.isFile()) throw new TransferError("Choose a file, not a folder.");
  if (info.size > MAX_TRANSFER_BYTES) {
    throw new TransferError(`Files over ${MAX_TRANSFER_BYTES / 1024 / 1024} MB can't be sent.`);
  }
  if (!Number.isSafeInteger(offset) || offset < 0) throw new TransferError("Bad offset.");
  const want = Math.max(0, Math.min(length, MAX_CHUNK_BYTES, info.size - offset));
  const buffer = Buffer.alloc(want);
  const handle = await open(path, "r");
  let read = 0;
  try {
    if (want > 0) ({ bytesRead: read } = await handle.read(buffer, 0, want, offset));
  } finally {
    await handle.close();
  }
  return {
    name: path.slice(path.lastIndexOf(sep) + 1),
    size: info.size,
    offset,
    data: buffer.subarray(0, read).toString("base64"),
    eof: offset + read >= info.size,
  };
}
