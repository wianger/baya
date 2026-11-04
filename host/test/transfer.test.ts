import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { openDownload, safeFileName, Uploads } from "../src/workspace/transfer.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function folder(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "baya-transfer-")));
  dirs.push(dir);
  return dir;
}

const progress: Array<[string, number, string?]> = [];
const report = (id: string, received: number, error?: string) => {
  progress.push(error ? [id, received, error] : [id, received]);
};

describe("uploads", () => {
  test("data frames land in the inbox under a free name, ignored by git", async () => {
    const root = folder();
    const uploads = new Uploads();
    const send = async (text: string) => {
      const { uploadId, dir } = await uploads.begin("phone", root, {
        name: "notes.txt",
        size: text.length,
      });
      expect(dir).toBe(join(root, ".baya", "uploads"));
      await uploads.attach("phone", uploadId, "c1", 7);
      uploads.data("c1", 7, 0, Buffer.from(text.slice(0, 3)), report);
      uploads.data("c1", 7, 3, Buffer.from(text.slice(3)), report);
      return uploads.finish("phone", uploadId);
    };
    const first = await send("hello world");
    const second = await send("again");
    expect(first).toEqual({
      name: "notes.txt",
      path: join(root, ".baya", "uploads", "notes.txt"),
      size: 11,
    });
    expect(second.name).toBe("notes (2).txt");
    expect(readFileSync(second.path, "utf8")).toBe("again");
    expect(readFileSync(join(root, ".baya", ".gitignore"), "utf8")).toBe("*\n");
  });

  test("a dropped upload resumes from where the disk got to", async () => {
    const root = folder();
    const uploads = new Uploads();
    const { uploadId } = await uploads.begin("phone", root, { name: "big.bin", size: 6 });
    await uploads.attach("phone", uploadId, "c1", 1);
    uploads.data("c1", 1, 0, Buffer.from("abc"), report);
    // A frame out of order (lost in between) is ignored.
    uploads.data("c1", 1, 4, Buffer.from("e"), report);
    uploads.detach("c1");
    // Frames from the gone connection no longer count.
    uploads.data("c1", 1, 3, Buffer.from("def"), report);
    const { received } = await uploads.attach("phone", uploadId, "c2", 9);
    expect(received).toBe(3);
    // A repeat of what already arrived is skipped.
    uploads.data("c2", 9, 0, Buffer.from("abc"), report);
    uploads.data("c2", 9, 3, Buffer.from("def"), report);
    const done = await uploads.finish("phone", uploadId);
    expect(readFileSync(done.path, "utf8")).toBe("abcdef");
    expect(progress.at(-1)).toEqual([uploadId, 6]);
  });

  test("another phone cannot touch it, and an unresumed upload goes", async () => {
    const root = folder();
    const uploads = new Uploads();
    const { uploadId } = await uploads.begin("phone", root, { name: "x", size: 4 });
    await expect(uploads.attach("other", uploadId, "c9", 1)).rejects.toThrow(/no longer open/);
    await uploads.attach("phone", uploadId, "c1", 1);
    uploads.data("c1", 1, 0, Buffer.from("abcdef"), report);
    await expect(uploads.finish("phone", uploadId)).rejects.toThrow(/larger than announced/);
    const again = await uploads.begin("phone", root, { name: "y", size: 1 });
    await uploads.attach("phone", again.uploadId, "c1", 2);
    uploads.detach("c1", 5);
    await new Promise((resolve) => setTimeout(resolve, 40));
    await expect(uploads.attach("phone", again.uploadId, "c2", 3)).rejects.toThrow(
      /no longer open/,
    );
    expect(
      readdirSync(join(root, ".baya", "uploads")).filter((n) => n.startsWith(".baya-upload-y")),
    ).toEqual([]);
  });

  test("a chosen folder must be inside the session", async () => {
    const root = folder();
    const other = folder();
    mkdirSync(join(root, "docs"));
    const uploads = new Uploads();
    const { dir } = await uploads.begin("p", root, { name: "a", size: 0, dir: join(root, "docs") });
    expect(dir).toBe(join(root, "docs"));
    await expect(uploads.begin("p", root, { name: "a", size: 0, dir: other })).rejects.toThrow(
      /outside/,
    );
  });

  test("names are made safe everywhere", () => {
    expect(safeFileName("../../etc/passwd")).toBe("passwd");
    expect(safeFileName("C:\\Users\\a\\report?.pdf")).toBe("report_.pdf");
    expect(safeFileName("CON.txt")).toBe("file-CON.txt");
    expect(safeFileName("..")).toBe("file");
    expect(safeFileName(".env")).toBe(".env");
    expect(safeFileName("照片 1.jpg")).toBe("照片 1.jpg");
  });
});

describe("downloads", () => {
  test("a file streams from an offset, only from inside the session", async () => {
    const root = folder();
    const file = join(root, "data.bin");
    writeFileSync(file, Buffer.alloc(150_000, 7));
    const download = await openDownload(root, file, 10_000);
    expect(download.size).toBe(150_000);
    const got: Array<[number, number]> = [];
    const end = await download.pump(
      async (offset, bytes) => {
        got.push([offset, bytes.length]);
      },
      () => false,
    );
    expect(end).toBe(150_000);
    expect(got).toEqual([
      [10_000, 64_000],
      [74_000, 64_000],
      [138_000, 12_000],
    ]);
    let calls = 0;
    await (await openDownload(root, file, 0)).pump(
      async () => {
        calls++;
      },
      () => calls >= 1,
    );
    expect(calls).toBe(1);

    const outside = join(folder(), "secret");
    writeFileSync(outside, "x");
    await expect(openDownload(root, outside, 0)).rejects.toThrow(/outside/);
    await expect(openDownload(root, root, 0)).rejects.toThrow(/not a folder/);
    await expect(openDownload(root, file, 200_000)).rejects.toThrow(/Bad offset/);
  });
});
