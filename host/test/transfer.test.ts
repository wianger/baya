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
import { downloadChunk, safeFileName, Uploads } from "../src/workspace/transfer.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function folder(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "baya-transfer-")));
  dirs.push(dir);
  return dir;
}

const b64 = (text: string) => Buffer.from(text).toString("base64");

describe("uploads", () => {
  test("pieces land in the inbox under a free name, ignored by git", async () => {
    const root = folder();
    const uploads = new Uploads();
    const send = async (text: string) => {
      const { uploadId, dir } = await uploads.begin("p", root, {
        name: "notes.txt",
        size: text.length,
      });
      expect(dir).toBe(join(root, ".baya", "uploads"));
      await uploads.chunk("p", uploadId, 0, b64(text.slice(0, 3)));
      await uploads.chunk("p", uploadId, 3, b64(text.slice(3)));
      return uploads.finish("p", uploadId);
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
    expect(readdirSync(join(root, ".baya", "uploads")).sort()).toEqual([
      "notes (2).txt",
      "notes.txt",
    ]);
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
    await expect(uploads.begin("p", root, { name: "a", size: 0, dir: "docs" })).rejects.toThrow(
      /inside/,
    );
  });

  test("out-of-order, oversized, foreign and cancelled uploads leave nothing", async () => {
    const root = folder();
    const uploads = new Uploads();
    const { uploadId } = await uploads.begin("p", root, { name: "x.bin", size: 4 });
    await expect(uploads.chunk("p", uploadId, 2, b64("ab"))).rejects.toThrow(
      /Expected bytes from 0/,
    );
    await expect(uploads.chunk("other", uploadId, 0, b64("ab"))).rejects.toThrow(/no longer open/);
    await uploads.chunk("p", uploadId, 0, b64("ab"));
    await expect(uploads.finish("p", uploadId)).rejects.toThrow(/Only 2 of 4/);
    await expect(uploads.chunk("p", uploadId, 2, b64("abc"))).rejects.toThrow(/larger/);
    expect(readdirSync(join(root, ".baya", "uploads"))).toEqual([]);

    const again = await uploads.begin("p", root, { name: "y", size: 1 });
    await uploads.drop("p");
    await expect(uploads.chunk("p", again.uploadId, 0, b64("a"))).rejects.toThrow(/no longer open/);
    expect(readdirSync(join(root, ".baya", "uploads"))).toEqual([]);
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
  test("a file comes back in pieces, only from inside the session", async () => {
    const root = folder();
    const file = join(root, "data.bin");
    writeFileSync(file, "0123456789");
    const first = await downloadChunk(root, file, 0, 4);
    expect(first).toMatchObject({ name: "data.bin", size: 10, offset: 0, eof: false });
    expect(Buffer.from(first.data, "base64").toString()).toBe("0123");
    const last = await downloadChunk(root, file, 4, 100);
    expect(Buffer.from(last.data, "base64").toString()).toBe("456789");
    expect(last.eof).toBe(true);

    const outside = join(folder(), "secret");
    writeFileSync(outside, "x");
    await expect(downloadChunk(root, outside, 0, 1)).rejects.toThrow(/outside/);
    await expect(downloadChunk(root, root, 0, 1)).rejects.toThrow(/not a folder/);
  });
});
