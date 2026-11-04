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

class TransferError extends Error {}

interface Upload {
  /** The phone (its key) that began it; it may resume from another connection. */
  owner: string;
  handle: FileHandle;
  part: string;
  dir: string;
  name: string;
  size: number;
  /** Bytes on disk. */
  received: number;
  /** Bytes accepted, written or queued. */
  next: number;
  writing: Promise<void>;
  failed: string | null;
  /** Where its data frames come in: a connection and the phone's stream id. */
  stream: { connection: string; id: number } | null;
  expiry: NodeJS.Timeout | null;
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

/** How long a half-sent upload waits for its phone to come back. */
const RESUME_WINDOW_MS = 30 * 60 * 1000;
/** Progress (and room to send more) is reported every this many bytes. */
const PROGRESS_EVERY = 512 * 1024;

/**
 * Files sent from the phone as binary data frames, written to a hidden
 * part file beside their destination and renamed into place once every
 * byte arrived. An upload belongs to the phone that began it: when its
 * connection drops it waits half an hour to be resumed.
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
      next: 0,
      writing: Promise.resolve(),
      failed: null,
      stream: null,
      expiry: null,
    });
    return { uploadId, dir };
  }

  /**
   * Data frames of stream [id] on [connection] now feed [uploadId]: at
   * the start, or again after a drop. Returns the bytes already on disk,
   * where the phone carries on from.
   */
  async attach(
    owner: string,
    uploadId: string,
    connection: string,
    id: number,
  ): Promise<{ received: number }> {
    const upload = this.get(owner, uploadId);
    if (!Number.isInteger(id) || id < 0 || id > 0xffffffff) {
      throw new TransferError("A stream id is required.");
    }
    if (upload.expiry) clearTimeout(upload.expiry);
    upload.expiry = null;
    await upload.writing;
    upload.next = upload.received;
    upload.stream = { connection, id };
    return { received: upload.received };
  }

  /**
   * A data frame: bytes of an upload at [offset]. Frames repeated after a
   * resume are skipped; [progress] hears how far the file got.
   */
  data(
    connection: string,
    id: number,
    offset: number,
    bytes: Buffer,
    progress: (uploadId: string, received: number, error?: string) => void,
  ): void {
    const found = [...this.open].find(
      ([, u]) => u.stream?.connection === connection && u.stream.id === id,
    );
    if (!found) return;
    const [uploadId, upload] = found;
    if (upload.failed || offset !== upload.next) return;
    if (upload.next + bytes.length > upload.size) {
      upload.failed = "The file is larger than announced.";
      progress(uploadId, upload.received, upload.failed);
      return;
    }
    upload.next += bytes.length;
    upload.writing = upload.writing.then(async () => {
      if (upload.failed) return;
      try {
        await upload.handle.write(bytes, 0, bytes.length, offset);
      } catch (error) {
        upload.failed = error instanceof Error ? error.message : String(error);
        progress(uploadId, upload.received, upload.failed);
        return;
      }
      const before = upload.received;
      upload.received += bytes.length;
      const done = upload.received === upload.size;
      if (
        done ||
        Math.floor(before / PROGRESS_EVERY) !== Math.floor(upload.received / PROGRESS_EVERY)
      ) {
        progress(uploadId, upload.received);
      }
    });
  }

  async finish(
    owner: string,
    uploadId: string,
  ): Promise<{ name: string; path: string; size: number }> {
    const upload = this.get(owner, uploadId);
    await upload.writing;
    if (upload.failed) throw new TransferError(upload.failed);
    if (upload.received !== upload.size) {
      throw new TransferError(`Only ${upload.received} of ${upload.size} bytes arrived.`);
    }
    this.open.delete(uploadId);
    if (upload.expiry) clearTimeout(upload.expiry);
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
    if (upload.expiry) clearTimeout(upload.expiry);
    await upload.writing.catch(() => {});
    await upload.handle.close().catch(() => {});
    await rm(upload.part, { force: true });
  }

  /** [connection] went away: its uploads wait a while to be resumed. */
  detach(connection: string, windowMs = RESUME_WINDOW_MS): void {
    for (const [uploadId, upload] of this.open) {
      if (upload.stream?.connection !== connection) continue;
      upload.stream = null;
      upload.expiry = setTimeout(() => void this.cancel(upload.owner, uploadId), windowMs);
      upload.expiry.unref?.();
    }
  }

  private get(owner: string, uploadId: string): Upload {
    const upload = this.open.get(uploadId);
    if (!upload || upload.owner !== owner)
      throw new TransferError("That upload is no longer open.");
    return upload;
  }
}

export const uploads = new Uploads();

/** Bytes of file data in one data frame. */
const DATA_PIECE = 64_000;

/**
 * Streams a session file to the phone as data frames from [offset] (where
 * a resumed download carries on), then says it ended. [closed] stops it.
 */
export async function openDownload(
  cwd: string,
  input: string,
  offset: number,
): Promise<{
  name: string;
  size: number;
  pump: (
    send: (offset: number, bytes: Buffer) => Promise<void>,
    closed: () => boolean,
  ) => Promise<number>;
}> {
  const root = await realpath(cwd);
  const path = await inside(root, input);
  const info = await stat(path);
  if (!info.isFile()) throw new TransferError("Choose a file, not a folder.");
  if (info.size > MAX_TRANSFER_BYTES) {
    throw new TransferError(`Files over ${MAX_TRANSFER_BYTES / 1024 / 1024} MB can't be sent.`);
  }
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > info.size) {
    throw new TransferError("Bad offset.");
  }
  const size = info.size;
  return {
    name: path.slice(path.lastIndexOf(sep) + 1),
    size,
    pump: async (send, closed) => {
      const handle = await open(path, "r");
      let at = offset;
      try {
        const buffer = Buffer.alloc(DATA_PIECE);
        while (at < size && !closed()) {
          const { bytesRead } = await handle.read(buffer, 0, Math.min(DATA_PIECE, size - at), at);
          if (bytesRead === 0) break;
          await send(at, Buffer.from(buffer.subarray(0, bytesRead)));
          at += bytesRead;
        }
      } finally {
        await handle.close();
      }
      return at;
    },
  };
}
